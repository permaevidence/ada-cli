import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Singleton actor: owns every connected MCP client, reads `~/.config/briglia/mcp.json`,
/// resolves Keychain-backed secrets into the spawn environment, bootstraps
/// servers on first use, caches the merged tool list as native
/// `ToolDefinition`s for the LLM tool block, and dispatches `tools/call`
/// requests from `ToolExecutor`.
///
/// Phase 1 behavior: lazy-but-eager. The first call to `allToolDefinitions()`
/// in a session triggers `bootstrap()` which spawns every configured server
/// in parallel, waits for each handshake to complete (or fail), and caches
/// the result for the lifetime of the session. Subsequent calls are O(1).
///
/// Tool-list stability is preserved by:
///   - alphabetical sort inside each client's refreshTools()
///   - alphabetical sort of server names when merging
///   - never re-spawning mid-session unless a client actually crashed
actor MCPRegistry {

    public static let shared = MCPRegistry()

    private struct Entry {
        let client: MCPClient
        let config: MCPServerConfig
        var failed: Bool
        var failureReason: String?
    }

    private var entries: [String: Entry] = [:]   // key = server name
    private var bootstrapTask: Task<Void, Never>?
    private var didBootstrap: Bool = false

    /// Canonical accepted-tool registry (`MCPToolSurface`), rebuilt from the
    /// connected clients' tool lists on every `allToolDefinitions()` call
    /// (once per turn) and after every reload. Every dispatch and every
    /// prompt-visible string derives from it.
    private var surface = MCPToolSurface.empty
    private var surfaceBuilt = false
    private var loggedRefusalServers: Set<String> = []

    private init() {}

    // MARK: - Public API

    /// Returns every accepted MCP tool as a native `ToolDefinition`, ready to
    /// append to the LLM tool block. Sorted deterministically by alias so the
    /// output is byte-stable across turns — critical for prompt-cache hits.
    ///
    /// Triggers bootstrap on first call and rebuilds the tool surface. Per-agent
    /// filtering (including always vs deferred) is handled by `MCPAgentRouting`.
    func allToolDefinitions() async -> [ToolDefinition] {
        await ensureBootstrapped()
        await rebuildSurface()
        return surface.sortedDefinitions
    }

    /// The current accepted-tool registry (built if needed). `MCPAgentRouting`
    /// snapshots it once per turn for its sync consumers.
    func currentSurface() async -> MCPToolSurface {
        await ensureBootstrapped()
        if !surfaceBuilt { await rebuildSurface() }
        return surface
    }

    private func rebuildSurface() async {
        var servers: [(config: MCPServerConfig, tools: [MCPTool])] = []
        for (_, entry) in entries.sorted(by: { $0.key < $1.key }) where !entry.failed {
            servers.append((entry.config, await entry.client.listedTools))
        }
        let built = MCPToolSurface.build(servers: servers)
        // Log refusals once per server (a hostile server would otherwise spam
        // the log every turn).
        var byServer: [String: [MCPToolSurface.Refusal]] = [:]
        for refusal in built.refusals { byServer[refusal.serverName, default: []].append(refusal) }
        for (serverName, refusals) in byServer.sorted(by: { $0.key < $1.key })
        where !loggedRefusalServers.contains(serverName) {
            loggedRefusalServers.insert(serverName)
            let detail = refusals.map { "\($0.toolName): \($0.reason)" }.joined(separator: "; ")
            DebugTelemetry.log(
                .toolError,
                summary: "mcp tools refused on \(serverName) (\(refusals.count))",
                detail: detail,
                isError: true
            )
        }
        surface = built
        surfaceBuilt = true
    }

    /// Compact summaries for the given server **handles**. Each entry carries
    /// the handle, an escaped description (user-provided or auto-generated
    /// from tool aliases), and the accepted-tool count. Used for the
    /// on-demand MCP section of the system prompt. Which servers are
    /// deferred is decided by MCPAgentRouting, not here.
    func serverSummaries(for handles: Set<String>) async -> [(name: String, description: String, toolCount: Int)] {
        let current = await currentSurface()
        var out: [(String, String, Int)] = []
        for handle in handles {
            guard let server = current.server(handle: handle), !server.aliases.isEmpty else { continue }
            out.append((handle, current.promptDescription(handle: handle), server.aliases.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Formatted text block describing every accepted tool on the server with
    /// this **handle** (raw server names are not accepted). Intended as the
    /// result of `tool_search`.
    func toolSchemasForServer(_ handle: String) async -> String? {
        let current = await currentSurface()
        return current.schemaListing(handle: handle)
    }

    /// Dispatch a tool call from `ToolExecutor` by the wire name the model
    /// used: a canonical alias, or — during the grace release — a legacy raw
    /// name that resolves through the validated reverse map to exactly one
    /// accepted tool. Unknown names never reach a server.
    func callTool(name: String, argumentsJSON: String) async -> MCPToolCallResult {
        let current = await currentSurface()
        return await dispatch(current.resolve(name: name), requested: name, argumentsJSON: argumentsJSON)
    }

    /// `mcp_call` dispatch: `serverHandle` must be a handle from the on-demand
    /// list; `tool` is the alias or its tool segment (legacy raw pairs resolve
    /// only through the reverse map while the grace flag is on).
    func callTool(serverHandle: String, tool: String, argumentsJSON: String) async -> MCPToolCallResult {
        let current = await currentSurface()
        let requested = "\(serverHandle)/\(tool)"
        return await dispatch(current.resolve(serverHandle: serverHandle, tool: tool),
                              requested: requested, argumentsJSON: argumentsJSON)
    }

    private func dispatch(_ resolution: MCPToolSurface.Resolution, requested: String, argumentsJSON: String) async -> MCPToolCallResult {
        let accepted: MCPToolSurface.AcceptedTool
        // The requested name is model-supplied text; neutralize before it is
        // echoed back into a tool result.
        let requested = MarkerNeutralizer.escape(requested)
        switch resolution {
        case .tool(let tool):
            accepted = tool
        case .unknown:
            return MCPToolCallResult(text: jsonError("Unknown MCP tool '\(requested)' — use tool_search(server: <handle>) to list the canonical tool names"), images: [])
        case .ambiguous(let owners):
            return MCPToolCallResult(text: jsonError("Legacy MCP tool name '\(requested)' is ambiguous (\(owners.joined(separator: ", "))) — use the canonical alias"), images: [])
        case .legacyRefused(let alias):
            let hint = alias.map { "use \($0)" } ?? "use the canonical alias from tool_search"
            return MCPToolCallResult(text: jsonError("Legacy MCP tool name '\(requested)' is no longer accepted — \(hint)"), images: [])
        }
        guard let entry = entries[accepted.serverName], !entry.failed else {
            let reason = entries[accepted.serverName]?.failureReason ?? "not installed or not configured"
            return MCPToolCallResult(text: jsonError("MCP server '\(accepted.serverHandle)' unavailable (\(reason))"), images: [])
        }

        // Parse arguments. Empty string → empty dict. Anything else must be a
        // JSON object.
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let args: [String: Any]
        if trimmed.isEmpty {
            args = [:]
        } else if let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = parsed
        } else {
            return MCPToolCallResult(text: jsonError("MCP tool '\(accepted.alias)' expected a JSON object for arguments"), images: [])
        }

        do {
            return try await entry.client.callTool(name: accepted.toolName, arguments: args)
        } catch {
            return MCPToolCallResult(text: jsonError("MCP tool '\(accepted.alias)' failed: \(error)"), images: [])
        }
    }

    /// Status snapshot for settings UI / telemetry. Reports every configured
    /// server — connected, disabled, or failed.
    func status() async -> [(name: String, connected: Bool, failed: Bool, reason: String?, toolCount: Int)] {
        await ensureBootstrapped()
        var out: [(String, Bool, Bool, String?, Int)] = []
        for (name, entry) in entries {
            let alive = await entry.client.isAlive
            let tools = await entry.client.listedTools
            out.append((name, alive, entry.failed, entry.failureReason, tools.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Kill every spawned server. Called on app termination.
    func shutdownAll() async {
        for entry in entries.values {
            await entry.client.shutdown()
        }
        entries.removeAll()
        didBootstrap = false
        bootstrapTask = nil
        surface = .empty
        surfaceBuilt = false
    }

    /// Tear down every running client and re-bootstrap from the current
    /// on-disk config. Called by Settings UI after mcp.json is rewritten so
    /// changes take effect without requiring an app restart.
    func reloadFromDisk() async {
        for entry in entries.values {
            await entry.client.shutdown()
        }
        entries.removeAll()
        didBootstrap = false
        bootstrapTask = nil
        surface = .empty
        surfaceBuilt = false
        loggedRefusalServers.removeAll()
        await ensureBootstrapped()
        await rebuildSurface()
    }

    // MARK: - Config persistence (for Settings UI)

    /// Public wrapper around the private on-disk loader. Used by the MCPs
    /// settings panel to render the current configuration.
    nonisolated static func loadConfigsFromDisk() -> [MCPServerConfig] {
        loadConfigs()
    }

    /// Write the full mcp.json atomically. Sorted by server name for
    /// reviewable diffs. Does NOT restart running clients — call
    /// `await MCPRegistry.shared.reloadFromDisk()` afterwards if the changes
    /// need to take effect immediately.
    nonisolated static func saveConfigsToDisk(_ configs: [MCPServerConfig]) throws {
        var servers: [String: Any] = [:]
        for cfg in configs.sorted(by: { $0.name < $1.name }) {
            var dict: [String: Any] = [
                "command": cfg.command,
                "args": cfg.arguments
            ]
            if !cfg.environment.isEmpty { dict["env"] = cfg.environment }
            if cfg.disabled { dict["disabled"] = true }
            if !cfg.secretRefs.isEmpty { dict["secretRefs"] = cfg.secretRefs }
            if let desc = cfg.description, !desc.isEmpty { dict["description"] = desc }
            servers[cfg.name] = dict
        }
        let root: [String: Any] = ["mcpServers": servers]
        let url = mcpConfigURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    public static func mcpConfigPath() -> String {
        mcpConfigURL().path
    }

    // MARK: - Bootstrap

    private func ensureBootstrapped() async {
        if didBootstrap { return }
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let task = Task { await self.bootstrap() }
        bootstrapTask = task
        await task.value
    }

    private func bootstrap() async {
        defer {
            didBootstrap = true
            bootstrapTask = nil
        }
        let configs = Self.loadConfigs()
        guard !configs.isEmpty else { return }

        // Spawn in parallel so one slow server (npx cold start) doesn't block
        // the others. Each task populates a local entry on success or a
        // failure marker on error.
        await withTaskGroup(of: (String, Entry).self) { group in
            for cfg in configs {
                group.addTask {
                    await Self.spawnOne(config: cfg)
                }
            }
            for await (name, entry) in group {
                entries[name] = entry
            }
        }
    }

    private static func spawnOne(config: MCPServerConfig) async -> (String, Entry) {
        if config.disabled {
            let client = MCPClient(config: config, resolvedEnvironment: [:])
            return (config.name, Entry(client: client, config: config, failed: true, failureReason: "disabled in mcp.json"))
        }

        let env = resolveEnvironment(for: config)
        let resolved = resolveExecutable(config: config)
        let client = MCPClient(config: resolved, resolvedEnvironment: env)

        do {
            try await client.start()
            try await client.initialize()
            DebugTelemetry.log(
                .toolStart,
                summary: "mcp spawn ok: \(config.name)",
                detail: "\(resolved.command) \(resolved.arguments.joined(separator: " "))"
            )
            return (config.name, Entry(client: client, config: config, failed: false, failureReason: nil))
        } catch {
            await client.shutdown()
            DebugTelemetry.log(
                .toolError,
                summary: "mcp spawn failed: \(config.name)",
                detail: String(describing: error),
                isError: true
            )
            return (config.name, Entry(
                client: client,
                config: config,
                failed: true,
                failureReason: String(describing: error)
            ))
        }
    }

    // MARK: - Config loading

    private static func loadConfigs() -> [MCPServerConfig] {
        let url = mcpConfigURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        guard let servers = root["mcpServers"] as? [String: Any] else { return [] }

        var out: [MCPServerConfig] = []
        for (name, raw) in servers {
            guard let dict = raw as? [String: Any],
                  let command = dict["command"] as? String else { continue }
            let args = (dict["args"] as? [String]) ?? []
            let env = (dict["env"] as? [String: String]) ?? [:]
            let disabled = (dict["disabled"] as? Bool) ?? false
            let secretRefs = (dict["secretRefs"] as? [String]) ?? []
            let desc = dict["description"] as? String
            out.append(MCPServerConfig(
                name: name,
                command: command,
                arguments: args,
                environment: env,
                disabled: disabled,
                secretRefs: secretRefs,
                description: desc
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func mcpConfigURL() -> URL {
        return StoragePaths.configRoot.appendingPathComponent("mcp.json")
    }

    /// Public path to mcp.json (bootstrap freshness check, prompts).
    nonisolated static var configFileURL: URL { mcpConfigURL() }

    // MARK: - Environment & executable resolution

    /// Merge: inherited PATH/HOME/etc. + config.env + Keychain-backed secrets.
    /// Keychain keys are `mcp_env_<server>_<VAR>` (populated via Settings in
    /// a later phase). Plaintext values in mcp.json's `env` block take
    /// precedence for explicit overrides, but users are expected to put
    /// secrets in the Keychain.
    private static func resolveEnvironment(for config: MCPServerConfig) -> [String: String] {
        var env = baseEnvironment()
        for (k, v) in config.environment { env[k] = v }
        for ref in config.secretRefs {
            let key = "mcp_env_\(config.name)_\(ref)"
            if let value = KeychainHelper.load(key: key), !value.isEmpty {
                env[ref] = value
            }
        }
        return env
    }

    private static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Augment PATH with common install locations so `npx`, `uvx`,
        // `bun`, `python3`, etc. resolve reliably from a GUI-launched
        // subprocess environment.
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(env["HOME"] ?? "")/.local/bin",
            "\(env["HOME"] ?? "")/.bun/bin",
            "\(env["HOME"] ?? "")/.cargo/bin"
        ]
        let existing = env["PATH"] ?? ""
        var parts = existing.split(separator: ":").map(String.init)
        for extra in extras where !parts.contains(extra) {
            parts.insert(extra, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }

    /// If `command` is bare (no slash), try to resolve via the augmented
    /// PATH. Returns the config with the absolute path filled in so MCPClient
    /// doesn't need to do its own lookup. Falls through untouched on miss.
    private static func resolveExecutable(config: MCPServerConfig) -> MCPServerConfig {
        if config.command.contains("/") { return config }
        let env = baseEnvironment()
        let path = env["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(config.command)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return MCPServerConfig(
                    name: config.name,
                    command: candidate,
                    arguments: config.arguments,
                    environment: config.environment,
                    disabled: config.disabled,
                    secretRefs: config.secretRefs,
                    description: config.description
                )
            }
        }
        return config
    }

    // MARK: - Name routing

    /// Tool conversion, aliasing and name resolution live in
    /// `MCPToolSurface` (Services/MCPToolSurface.swift). The registry only
    /// answers "does this wire name belong to the MCP namespace?" — every
    /// actual lookup goes through the accepted-tool registry.
    public static func isMCPPrefixed(_ name: String) -> Bool {
        name.hasPrefix("mcp__")
    }

    // MARK: - Helpers

    private func jsonError(_ msg: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: ["error": msg], options: [.withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{\"error\": \"MCP error\"}"
    }
}

// MARK: - Node.js direct installer

/// Downloads the official Node.js LTS tarball from nodejs.org (verified
/// against the release's SHASUMS256.txt), extracts it to ~/.local/node and
/// links node/npm/npx into ~/.local/bin — a directory every Briglia subprocess
/// PATH already covers (MCPRegistry.baseEnvironment, BashTools.augmentedPath).
/// No Homebrew, no admin password. Mirrors
/// GoogleWorkspaceService.installGwsBinary().
enum NodeInstaller {
    static var installRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/node", isDirectory: true)
    }
    static var binDir: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Latest LTS version string (e.g. "v22.17.0") from the nodejs.org release
    /// index. Entries are newest-first; `lts` is `false` or the codename string.
    private static func latestLTSVersion() async throws -> String {
        guard let url = URL(string: "https://nodejs.org/dist/index.json") else {
            throw installError("internal error: malformed index URL")
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw installError("release index HTTP \(code)")
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw installError("unreadable release index")
        }
        for entry in list {
            if entry["lts"] is String, let version = entry["version"] as? String {
                return version
            }
        }
        throw installError("no LTS release in index")
    }

    private static func installError(_ message: String) -> NSError {
        NSError(domain: "NodeInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Returns nil on success, or a human-readable failure detail. `progress`
    /// receives user-facing status lines (download percentage, install phase).
    static func installNode(progress: (@Sendable (String) -> Void)? = nil) async -> String? {
        // nodejs.org/dist asset names, verified against the published file
        // list: darwin-{arm64,x64} and linux-{arm64,x64}.
        #if os(Linux)
        #if arch(arm64)
        let arch = "linux-arm64"
        #else
        let arch = "linux-x64"
        #endif
        #else
        #if arch(arm64)
        let arch = "darwin-arm64"
        #else
        let arch = "darwin-x64"
        #endif
        #endif
        do {
            progress?("Finding the latest Node.js version…")
            let version = try await latestLTSVersion()
            let file = "node-\(version)-\(arch).tar.gz"
            let base = "https://nodejs.org/dist/\(version)/"
            guard let tarURL = URL(string: base + file),
                  let shaURL = URL(string: base + "SHASUMS256.txt") else {
                return "internal error: malformed download URL"
            }

            let tarData = try await GoogleWorkspaceService.downloadReportingProgress(
                from: tarURL, label: "Downloading Node.js \(version)", progress: progress)
            let (shaData, shaResp) = try await URLSession.shared.data(from: shaURL)
            if let code = (shaResp as? HTTPURLResponse)?.statusCode, code != 200 {
                return "checksum download failed (HTTP \(code))"
            }
            progress?("Installing Node.js…")
            // SHASUMS256.txt format: one "<hex>  <filename>" line per asset.
            guard let shaText = String(data: shaData, encoding: .utf8),
                  let line = shaText.split(separator: "\n").map(String.init)
                      .first(where: { $0.hasSuffix(" \(file)") }),
                  let expected = line.split(separator: " ").first.map(String.init)?.lowercased(),
                  expected.count == 64 else {
                return "checksum for \(file) not found in SHASUMS256.txt"
            }
            let actual = SHA256.hash(data: tarData).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                return "checksum mismatch — download corrupted, retry"
            }

            let fm = FileManager.default
            let tmpDir = fm.temporaryDirectory.appendingPathComponent("node-install-\(UUID().uuidString)")
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmpDir) }
            let tarPath = tmpDir.appendingPathComponent(file)
            try tarData.write(to: tarPath)

            let untar = await GoogleWorkspaceService.runProcessAsync(
                executable: "/usr/bin/tar",
                args: ["-xzf", tarPath.path, "-C", tmpDir.path],
                timeoutSeconds: 120
            )
            if let detail = untar.failureDetail {
                return "extraction failed: \(detail)"
            }
            let extractedRoot = tmpDir.appendingPathComponent("node-\(version)-\(arch)", isDirectory: true)
            guard fm.fileExists(atPath: extractedRoot.appendingPathComponent("bin/node").path) else {
                return "archive did not contain bin/node"
            }

            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: installRoot.path) {
                try fm.removeItem(at: installRoot)
            }
            try fm.moveItem(at: extractedRoot, to: installRoot)

            #if os(macOS)
            // Belt-and-braces: quarantined unnotarized binaries won't exec.
            _ = await GoogleWorkspaceService.runProcessAsync(
                executable: "/usr/bin/xattr",
                args: ["-dr", "com.apple.quarantine", installRoot.path],
                timeoutSeconds: 60
            )
            #endif

            for tool in ["node", "npm", "npx"] {
                let link = binDir.appendingPathComponent(tool)
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(at: link, withDestinationURL: installRoot.appendingPathComponent("bin/\(tool)"))
            }

            // Smoke tests through the symlinks. npx runs via `#!/usr/bin/env node`,
            // so this also proves ~/.local/bin is on the subprocess PATH.
            let nodeProbe = await GoogleWorkspaceService.runProcessAsync(
                executable: binDir.appendingPathComponent("node").path,
                args: ["--version"], timeoutSeconds: 15
            )
            guard nodeProbe.stdout != nil else {
                return "installed node failed to run: \(nodeProbe.failureDetail ?? "unknown error")"
            }
            let npxProbe = await GoogleWorkspaceService.runProcessAsync(
                executable: binDir.appendingPathComponent("npx").path,
                args: ["--version"], timeoutSeconds: 30
            )
            guard npxProbe.stdout != nil else {
                return "installed npx failed to run: \(npxProbe.failureDetail ?? "unknown error")"
            }
            return nil
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    /// Absolute path of an installed node binary, or nil. Checks the same
    /// locations the subprocess PATH covers.
    static func detectNode() -> String? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(NSHomeDirectory())/.local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

// MARK: - Automatic browser-automation setup

/// Turns on autonomous web browsing without an onboarding step: registers the
/// Playwright MCP server once and installs Node.js in the background if it's
/// missing. Runs on every launch of the main window; both halves are no-ops
/// when already done. The Playwright browser itself downloads on first use.
enum BrowserAutomationBootstrap {
    private static let autoConfiguredKey = "playwright_auto_configured"

    static func ensureConfigured() async {
        var configs = MCPRegistry.loadConfigsFromDisk()
        let hasEntry = configs.contains { $0.name == "playwright" }

        // The "don't re-add after deliberate removal" flag lives in
        // UserDefaults (~/Library/Preferences), which survives a full wipe of
        // ~/.config/briglia. Distinguish the two cases by the config file itself:
        // a user who removed just the playwright entry leaves mcp.json on
        // disk, while a wiped/fresh machine has no file at all — treat that
        // as a fresh install and bootstrap again. (Observed live: a full
        // uninstall + reinstall came up without the Browse subagent because
        // the stale flag suppressed re-registration.)
        if !FileManager.default.fileExists(atPath: MCPRegistry.configFileURL.path) {
            UserDefaults.standard.removeObject(forKey: autoConfiguredKey)
        }

        // Register the server exactly once. If an entry exists — including one
        // the user disabled or edited — leave it alone; and once we've
        // auto-added it, never re-add after a deliberate removal.
        if !hasEntry && !UserDefaults.standard.bool(forKey: autoConfiguredKey) {
            configs.append(MCPServerConfig(
                name: "playwright",
                command: "npx",
                arguments: ["@playwright/mcp@latest"],
                description: "Browser automation (drives a local browser for the Browse subagent)"
            ))
            do {
                try MCPRegistry.saveConfigsToDisk(configs)
                UserDefaults.standard.set(true, forKey: autoConfiguredKey)
                await MCPRegistry.shared.reloadFromDisk()
                await MCPAgentRouting.refreshFromRegistry()
            } catch {
                NSLog("BrowserAutomationBootstrap: failed to save playwright config: \(error.localizedDescription)")
            }
        } else if hasEntry {
            UserDefaults.standard.set(true, forKey: autoConfiguredKey)
        }

        // Playwright runs through npx: fetch Node quietly if it's absent.
        // On failure just log — the next launch retries while node is missing.
        let playwrightActive = MCPRegistry.loadConfigsFromDisk()
            .contains { $0.name == "playwright" && !$0.disabled }
        if playwrightActive && NodeInstaller.detectNode() == nil {
            if let failure = await NodeInstaller.installNode() {
                NSLog("BrowserAutomationBootstrap: background Node.js install failed: \(failure)")
            }
        }
    }
}
