import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Singleton actor: owns every connected MCP client, reads `~/.config/ada/mcp.json`,
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

    private init() {}

    // MARK: - Public API

    /// Returns every MCP tool converted to a native `ToolDefinition`, ready
    /// to append to the LLM tool block. Sorted deterministically by prefixed
    /// name (`mcp__<server>__<tool>`) so the output is byte-stable across
    /// turns — critical for prompt-cache hits.
    ///
    /// Triggers bootstrap on first call. Later calls reuse the cached list.
    /// Per-agent filtering (including always vs deferred) is handled by
    /// `MCPAgentRouting`, not here.
    func allToolDefinitions() async -> [ToolDefinition] {
        await ensureBootstrapped()
        var combined: [MCPTool] = []
        for entry in entries.values where !entry.failed {
            let tools = await entry.client.listedTools
            combined.append(contentsOf: tools)
        }
        combined.sort { $0.prefixedName < $1.prefixedName }
        return combined.map(Self.convertToToolDefinition)
    }

    /// Compact summaries for the specified server names. Each entry includes:
    /// server name, description (user-provided or auto), and tool count.
    /// Used to inject lightweight hints into the system prompt for deferred MCPs.
    /// Which servers are deferred is decided by MCPAgentRouting, not here.
    func serverSummaries(for serverNames: Set<String>) async -> [(name: String, description: String, toolCount: Int)] {
        await ensureBootstrapped()
        var out: [(String, String, Int)] = []
        for name in serverNames {
            guard let entry = entries[name], !entry.failed else { continue }
            let tools = await entry.client.listedTools
            guard !tools.isEmpty else { continue }
            let desc = entry.config.description ?? Self.autoDescription(tools: tools)
            out.append((name, desc, tools.count))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Returns a formatted text block describing every tool on `serverName`,
    /// including parameter schemas. Intended as the result of `tool_search`.
    func toolSchemasForServer(_ serverName: String) async -> String? {
        await ensureBootstrapped()
        guard let entry = entries[serverName], !entry.failed else { return nil }
        let tools = await entry.client.listedTools
        guard !tools.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("MCP server '\(serverName)' — \(tools.count) tools:")
        lines.append("")
        for tool in tools.sorted(by: { $0.toolName < $1.toolName }) {
            lines.append("## \(tool.toolName)")
            if !tool.description.isEmpty {
                lines.append(tool.description)
            }
            let props = (tool.inputSchema["properties"] as? [String: Any]) ?? [:]
            let required = Set((tool.inputSchema["required"] as? [String]) ?? [])
            if !props.isEmpty {
                lines.append("Parameters:")
                for key in props.keys.sorted() {
                    guard let dict = props[key] as? [String: Any] else { continue }
                    let type = (dict["type"] as? String) ?? "string"
                    let desc = (dict["description"] as? String) ?? ""
                    let req = required.contains(key) ? " (required)" : ""
                    var enumNote = ""
                    if let vals = dict["enum"] as? [Any] {
                        enumNote = " — enum: \(vals.map { "\($0)" }.joined(separator: ", "))"
                    }
                    lines.append("  - \(key): \(type)\(req)\(enumNote)\(desc.isEmpty ? "" : " — \(desc)")")
                }
            } else {
                lines.append("Parameters: none")
            }
            lines.append("")
        }
        lines.append("Use mcp_call(server: \"\(serverName)\", tool: \"<tool_name>\", arguments: {...}) to invoke.")
        return lines.joined(separator: "\n")
    }

    /// Auto-generate a short description from tool names (fallback when user
    /// hasn't provided one). Shows up to 5 names, then "and N more".
    private static func autoDescription(tools: [MCPTool]) -> String {
        let names = tools.map(\.toolName).sorted()
        if names.count <= 5 {
            return "Provides: \(names.joined(separator: ", "))"
        }
        let first5 = names.prefix(5).joined(separator: ", ")
        return "Provides: \(first5), and \(names.count - 5) more"
    }

    /// Dispatch a tool call from `ToolExecutor`. The argument is the prefixed
    /// name (`mcp__<server>__<tool>`) surfaced to the LLM. Routes to the
    /// right client and returns the result (text plus any decoded image
    /// blocks); errors come back as a text-only JSON error string.
    func callTool(prefixedName: String, argumentsJSON: String) async -> MCPToolCallResult {
        await ensureBootstrapped()
        guard let (serverName, toolName) = Self.splitPrefixedName(prefixedName) else {
            return MCPToolCallResult(text: jsonError("Malformed MCP tool name '\(prefixedName)'"), images: [])
        }
        guard let entry = entries[serverName], !entry.failed else {
            let reason = entries[serverName]?.failureReason ?? "not installed or not configured"
            return MCPToolCallResult(text: jsonError("MCP server '\(serverName)' unavailable (\(reason))"), images: [])
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
            return MCPToolCallResult(text: jsonError("MCP tool '\(prefixedName)' expected a JSON object for arguments"), images: [])
        }

        do {
            return try await entry.client.callTool(name: toolName, arguments: args)
        } catch {
            return MCPToolCallResult(text: jsonError("MCP tool '\(prefixedName)' failed: \(error)"), images: [])
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
        await ensureBootstrapped()
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

    // MARK: - Tool conversion (MCP inputSchema → ToolDefinition)

    /// Best-effort conversion from MCP's raw JSON-Schema `inputSchema` to our
    /// flat `FunctionParameters` shape. Nested-object properties are
    /// flattened to `type: "object"` with a descriptive note. Fully captured
    /// fidelity is deferred to a later phase (rawSchema pass-through).
    static func convertToToolDefinition(_ tool: MCPTool) -> ToolDefinition {
        let schema = tool.inputSchema
        let rawProps = (schema["properties"] as? [String: Any]) ?? [:]
        let required = (schema["required"] as? [String]) ?? []

        var properties: [String: ParameterProperty] = [:]
        for (key, raw) in rawProps {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? "string"
            var description = (dict["description"] as? String) ?? ""
            var enumValues: [String]? = nil
            if let vals = dict["enum"] as? [Any] {
                enumValues = vals.compactMap { v -> String? in
                    if let s = v as? String { return s }
                    return String(describing: v)
                }
            }
            var itemsSchema: ArrayItemsSchema? = nil
            switch type {
            case "array":
                if let items = dict["items"] as? [String: Any] {
                    let itemType = (items["type"] as? String) ?? "string"
                    itemsSchema = ArrayItemsSchema(type: itemType)
                } else {
                    itemsSchema = ArrayItemsSchema(type: "string")
                }
            case "object":
                // Flatten: note sub-shape in description so the LLM can still form valid args.
                if let sub = dict["properties"] as? [String: Any], !sub.isEmpty {
                    let keys = sub.keys.sorted().joined(separator: ", ")
                    description = description.isEmpty
                        ? "JSON object with fields: \(keys)"
                        : "\(description) (JSON object with fields: \(keys))"
                }
            default:
                break
            }

            properties[key] = ParameterProperty(
                type: type,
                description: description,
                enumValues: enumValues,
                items: itemsSchema
            )
        }

        let fullDescription: String
        if tool.description.isEmpty {
            fullDescription = "Tool provided by MCP server '\(tool.serverName)'."
        } else {
            fullDescription = "\(tool.description)\n\n(Provided by MCP server '\(tool.serverName)'.)"
        }

        return ToolDefinition(
            function: FunctionDefinition(
                name: tool.prefixedName,
                description: fullDescription,
                parameters: FunctionParameters(
                    properties: properties,
                    required: required
                )
            )
        )
    }

    // MARK: - Name routing

    /// Split `mcp__<server>__<tool>` into (server, tool). Returns nil if the
    /// prefix doesn't parse.
    static func splitPrefixedName(_ prefixed: String) -> (server: String, tool: String)? {
        guard prefixed.hasPrefix("mcp__") else { return nil }
        let trimmed = String(prefixed.dropFirst("mcp__".count))
        guard let sep = trimmed.range(of: "__") else { return nil }
        let server = String(trimmed[..<sep.lowerBound])
        let tool = String(trimmed[sep.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

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
/// links node/npm/npx into ~/.local/bin — a directory every Ada subprocess
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
        // ~/.config/ada. Distinguish the two cases by the config file itself:
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
