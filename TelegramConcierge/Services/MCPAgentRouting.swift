import Foundation

/// Per-agent MCP tool routing.
///
/// Phase 2 of the MCP subsystem. Decides which MCP-backed tools each agent
/// (main, built-in subagents, user-defined subagents) is allowed to see in
/// its prompt tool block, and whether those tools are loaded **always**
/// (in the tools array every turn) or **deferred** (discoverable on-demand
/// via `tool_search` + `mcp_call`).
///
/// The routing file lives at `~/.config/briglia/mcp-routing.json`:
///
/// ```json
/// {
///   "main": {
///     "always": [],
///     "deferred": ["mcp__playwright__*"]
///   },
///   "Browse": {
///     "always": ["mcp__playwright__*"]
///   }
/// }
/// ```
///
/// For backward compatibility, a plain array value is treated as `always`:
///
/// ```json
/// { "Browse": ["mcp__playwright__*"] }
/// ```
///
/// is equivalent to:
///
/// ```json
/// { "Browse": { "always": ["mcp__playwright__*"] } }
/// ```
///
/// Each entry is a list of patterns matching **tool aliases**
/// (`mcp__<server handle>__<tool segment>`, see `MCPToolSurface`). Supported
/// pattern shapes:
///   - Exact alias:                     `"mcp__playwright__browser_click"`
///   - Trailing-wildcard (server-wide): `"mcp__playwright__*"` — exact per
///     server by construction: aliases embed the server handle and no other
///     server's aliases share that prefix
///   - Double wildcard:                 `"mcp__*"` (every MCP — escape hatch)
///
/// Compatibility (Release A only): patterns written against the legacy raw
/// names (`mcp__<server name>__<tool name>`) are dual-matched through the
/// registry's validated reverse map, and persisted routes are rewritten to
/// the canonical aliases on load (`migrateRoutingFile`). From Release B on,
/// patterns match aliases only (`MCPToolSurface.legacyRawNameGraceEnabled`).
///
/// If an agent has no entry in the file, the subagent's `mcpToolPatterns`
/// (set on `SubagentType`) are used as a fallback (always mode).
/// Main agent always falls back to empty.
///
/// The routing file is loaded lazily on first query and cached in-process.
/// `reload()` forces a re-read (used after profile imports rewrite it).
enum MCPAgentRouting {

    // MARK: - Per-agent routing entry

    /// Parsed routing for a single agent: which MCP patterns are always-loaded
    /// and which are deferred (on-demand via tool_search/mcp_call).
    struct AgentRouting: Equatable {
        var always: [String]
        var deferred: [String]

        var isEmpty: Bool { always.isEmpty && deferred.isEmpty }
        /// All patterns combined (used when an agent should see everything directly).
        var allPatterns: [String] { always + deferred }
    }

    /// One routing reference that could not be resolved or is malformed.
    /// Reported by `briglia doctor`; the referenced pattern is kept verbatim,
    /// never dropped.
    struct Diagnostic: Codable, Equatable {
        let source: String      // e.g. "mcp-routing.json main.deferred" or "mcp_tools Browse"
        let pattern: String
        let issue: String
        let suggestion: String?
    }

    // MARK: - Cached state

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedConfig: [String: AgentRouting]?
    nonisolated(unsafe) private static var cachedInstalledServers: Set<String> = []
    nonisolated(unsafe) private static var cachedMCPToolNames: Set<String> = []
    nonisolated(unsafe) private static var cachedSurface: MCPToolSurface?
    nonisolated(unsafe) private static var lastPersistedDiagnostics: [Diagnostic]?

    // MARK: - Public API

    /// Filter the full MCP tool list down to what `agent` is allowed to see
    /// in its tools array (i.e. the **always** tools). Deferred tools are
    /// excluded — use `deferredServers(forAgent:allTools:)` for those.
    ///
    /// Safe to call from sync contexts — routing config is loaded from disk
    /// lazily and cached.
    static func filterMcpTools(
        forAgent agent: String,
        allTools: [ToolDefinition],
        fallbackPatterns: [String]?
    ) -> [ToolDefinition] {
        let routing = resolveRouting(forAgent: agent, fallbackPatterns: fallbackPatterns)
        let patterns = routing.always
        if patterns.isEmpty { return [] }

        return allTools.filter { tool in
            patterns.contains { matches(pattern: $0, name: tool.function.name) }
        }
    }

    /// Returns the set of MCP server **handles** that are **deferred** for
    /// `agent`. ConversationManager uses this to fetch summaries for the
    /// system prompt.
    static func deferredServers(
        forAgent agent: String,
        allTools: [ToolDefinition],
        fallbackPatterns: [String]?
    ) -> Set<String> {
        let routing = resolveRouting(forAgent: agent, fallbackPatterns: fallbackPatterns)
        let patterns = routing.deferred
        if patterns.isEmpty { return [] }

        // Find all tools matching deferred patterns, extract unique handles.
        // Aliases embed the handle, so the split is exact without a lookup.
        var handles: Set<String> = []
        for tool in allTools {
            if patterns.contains(where: { matches(pattern: $0, name: tool.function.name) }) {
                if let parts = MCPNaming.splitAlias(tool.function.name) {
                    handles.insert(parts.handle)
                }
            }
        }
        return handles
    }

    /// Returns ALL tools this agent can access (always + deferred combined).
    /// Used by SubagentRunner where subagents get direct access to everything
    /// routed to them regardless of loading mode.
    static func allToolsForAgent(
        agent: String,
        allTools: [ToolDefinition],
        fallbackPatterns: [String]?
    ) -> [ToolDefinition] {
        let routing = resolveRouting(forAgent: agent, fallbackPatterns: fallbackPatterns)
        let patterns = routing.allPatterns
        if patterns.isEmpty { return [] }

        return allTools.filter { tool in
            patterns.contains { matches(pattern: $0, name: tool.function.name) }
        }
    }

    /// Effective MCP patterns (always + deferred) for an agent, after the
    /// routing file's override is applied. Used by the Agent tool description
    /// to advertise each subagent's real MCP surface, not just its built-in
    /// default. Callers interpolating this into a prompt must escape it.
    static func effectivePatterns(forAgent agent: String, fallbackPatterns: [String]?) -> [String] {
        resolveRouting(forAgent: agent, fallbackPatterns: fallbackPatterns).allPatterns
    }

    /// Resolve the full routing for an agent (always + deferred).
    private static func resolveRouting(forAgent agent: String, fallbackPatterns: [String]?) -> AgentRouting {
        let config = loadConfigIfNeeded()
        if let entry = config[agent] ?? config[caseMatchedAgentKey(agent, in: config) ?? ""] {
            return entry
        }
        // Fallback: subagent's built-in patterns default to always mode
        return AgentRouting(always: fallbackPatterns ?? [], deferred: [])
    }

    /// Sync-readable snapshot of MCP servers (raw config names) known to the
    /// registry at the most recent `refreshFromRegistry()` call. Used by
    /// `SubagentTypes.all()` to decide whether to register the Browse
    /// built-in (it only appears when their backing MCP is actually
    /// installed). Never interpolated into prompts.
    static func installedServers() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedInstalledServers
    }

    /// Sync-readable list of currently-advertised MCP tool aliases.
    /// Populated by `refreshFromRegistry()`.
    static func currentToolNames() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedMCPToolNames
    }

    /// Sync snapshot of the accepted-tool registry taken by the last
    /// `refreshFromRegistry()`; nil before the first refresh.
    static func currentSurfaceSnapshot() -> MCPToolSurface? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedSurface
    }

    /// Pull fresh state from the registry and update the sync caches.
    /// ConversationManager calls this at the top of every turn, just before
    /// assembling the tool list, so sync consumers (SubagentTypes.all() et al)
    /// see up-to-date state without needing their own async path. It also
    /// rewrites persisted routes to canonical aliases (§H1.7) and records
    /// unresolved references for `doctor`.
    static func refreshFromRegistry() async {
        let status = await MCPRegistry.shared.status()
        let tools = await MCPRegistry.shared.allToolDefinitions()
        let surface = await MCPRegistry.shared.currentSurface()
        let installed = Set(status.filter { $0.connected && !$0.failed }.map { $0.name })
        let toolNames = Set(tools.map { $0.function.name })
        setRegistryCache(installed: installed, toolNames: toolNames, surface: surface)
        migrateRoutingFile(surface: surface)
    }

    /// Sync shim for updating the cache — keeps the lock manipulation out
    /// of the async `refreshFromRegistry()` body.
    private static func setRegistryCache(installed: Set<String>, toolNames: Set<String>, surface: MCPToolSurface) {
        cacheLock.lock()
        cachedInstalledServers = installed
        cachedMCPToolNames = toolNames
        cachedSurface = surface
        cacheLock.unlock()
    }

    /// Test seam: install a registry snapshot without spawning servers.
    static func setSurfaceForTesting(_ surface: MCPToolSurface?) {
        cacheLock.lock()
        cachedSurface = surface
        cacheLock.unlock()
    }

    /// Force re-read of the routing JSON on next access. Call after another
    /// writer (profile import) rewrote the file.
    static func reload() {
        cacheLock.lock()
        cachedConfig = nil
        cacheLock.unlock()
    }

    /// Write the full routing config to disk. Routes are canonicalized
    /// against the last registry snapshot first (an imported profile that
    /// names legacy raw tools is rewritten on the way in; unresolvable
    /// entries are kept verbatim).
    static func save(config input: [String: AgentRouting]) throws {
        var config = input
        if let surface = currentSurfaceSnapshot() {
            config = canonicalized(config, surface: surface).config
        }
        let url = routingURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Serialize: if deferred is empty, write as plain array for cleanliness
        var dict: [String: Any] = [:]
        for (agent, routing) in config {
            if routing.deferred.isEmpty {
                dict[agent] = routing.always
            } else {
                var obj: [String: Any] = ["always": routing.always]
                obj["deferred"] = routing.deferred
                dict[agent] = obj
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        cacheLock.lock()
        cachedConfig = config
        cacheLock.unlock()
    }

    /// Read the current routing config (creating an empty one in memory if
    /// the file is missing).
    static func currentConfig() -> [String: AgentRouting] {
        return loadConfigIfNeeded()
    }

    // MARK: - Pattern matching

    /// Conservative pattern charset: alias characters plus `.` (legacy raw
    /// names may carry dots), with an optional trailing `*`. Anything else is
    /// rejected — reported by doctor, never matched.
    static func isValidPattern(_ pattern: String) -> Bool {
        var body = Substring(pattern)
        if body.hasSuffix("*") { body = body.dropLast() }
        guard !body.isEmpty else { return false }
        guard pattern.count <= 200 else { return false }
        return body.unicodeScalars.allSatisfy { scalar in
            MCPNaming.isAllowedCharacter(scalar) || scalar == "."
        }
    }

    /// Match `name` (an alias) against `pattern`. Supported shapes:
    ///   - Exact:        "mcp__playwright__browser_click"
    ///   - Suffix glob:  "mcp__playwright__*"
    ///   - Broad glob:   "mcp__*"
    /// During the grace release a legacy raw pattern is first canonicalized
    /// through the registry snapshot (exact names via the validated reverse
    /// map — unique owners only; per-server wildcards via the server-name →
    /// handle map). Invalid patterns never match.
    static func matches(pattern: String, name: String) -> Bool {
        let canonical = canonicalPattern(pattern, surface: currentSurfaceSnapshot())
        guard isValidPattern(canonical) else { return false }
        return literalMatch(pattern: canonical, name: name)
    }

    private static func literalMatch(pattern: String, name: String) -> Bool {
        if pattern == name { return true }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        return false
    }

    /// Canonical (alias-based) form of a pattern for the given registry
    /// snapshot; the pattern itself when it is already canonical or cannot be
    /// resolved. Idempotent.
    static func canonicalPattern(_ pattern: String, surface: MCPToolSurface?) -> String {
        guard let surface, pattern.hasPrefix(MCPNaming.prefix) else { return pattern }
        if pattern.hasSuffix("*") {
            let body = String(pattern.dropLast())
            guard body != MCPNaming.prefix, body.hasSuffix(MCPNaming.separator) else { return pattern }
            let middle = String(body.dropFirst(MCPNaming.prefix.count).dropLast(MCPNaming.separator.count))
            guard !middle.isEmpty else { return pattern }
            if surface.server(handle: middle) != nil { return pattern }
            guard MCPToolSurface.legacyRawNameGraceEnabled,
                  let handle = surface.handle(forServerName: middle), handle != middle else { return pattern }
            return MCPNaming.serverWildcard(handle: handle)
        }
        if surface.tools[pattern] != nil { return pattern }
        guard MCPToolSurface.legacyRawNameGraceEnabled,
              let alias = surface.uniqueLegacyAliases[pattern] else { return pattern }
        return alias
    }

    /// Whether a (canonical) pattern selects at least one accepted tool.
    static func patternMatchesAnyTool(_ pattern: String, surface: MCPToolSurface) -> Bool {
        surface.tools.keys.contains { literalMatch(pattern: pattern, name: $0) }
    }

    // MARK: - Routing migration and diagnostics (§H1.7)

    /// Rewrite every routing entry to its canonical alias where the registry
    /// resolves it; collect diagnostics for entries that are malformed or
    /// match nothing. Entries are never dropped.
    static func canonicalized(_ config: [String: AgentRouting], surface: MCPToolSurface)
        -> (config: [String: AgentRouting], changed: Bool, diagnostics: [Diagnostic]) {
        var out = config
        var changed = false
        var diagnostics: [Diagnostic] = []
        func rewrite(_ list: [String], source: String) -> [String] {
            list.map { pattern in
                let canonical = canonicalPattern(pattern, surface: surface)
                if canonical != pattern { changed = true }
                if let diagnostic = diagnose(canonical, original: pattern, source: source, surface: surface) {
                    diagnostics.append(diagnostic)
                }
                return canonical
            }
        }
        for agent in config.keys.sorted() {
            guard let routing = config[agent] else { continue }
            out[agent] = AgentRouting(
                always: rewrite(routing.always, source: "mcp-routing.json \(agent).always"),
                deferred: rewrite(routing.deferred, source: "mcp-routing.json \(agent).deferred")
            )
        }
        return (out, changed, diagnostics)
    }

    /// Diagnostic for one canonical pattern, or nil when it is valid and
    /// selects at least one accepted tool.
    static func diagnose(_ canonical: String, original: String, source: String, surface: MCPToolSurface) -> Diagnostic? {
        guard isValidPattern(canonical) else {
            return Diagnostic(source: source, pattern: original,
                              issue: "pattern uses characters outside [A-Za-z0-9_.-] (plus a trailing *) and is ignored",
                              suggestion: nil)
        }
        if patternMatchesAnyTool(canonical, surface: surface) { return nil }
        var suggestion: String? = nil
        if canonical.hasSuffix("*"), canonical != MCPNaming.prefix + "*" {
            let body = String(canonical.dropLast())
            if body.hasPrefix(MCPNaming.prefix), body.hasSuffix(MCPNaming.separator) {
                let middle = String(body.dropFirst(MCPNaming.prefix.count).dropLast(MCPNaming.separator.count))
                if let handle = surface.handle(forServerName: middle), handle != middle {
                    suggestion = "use \(MCPNaming.serverWildcard(handle: handle))"
                } else if surface.server(handle: middle) == nil {
                    suggestion = "server '\(middle)' is not connected (not configured, disabled, or failed to start)"
                }
            }
        } else if let owners = surface.legacyReverse[canonical], owners.count > 1 {
            suggestion = "legacy name is ambiguous; use one of: \(owners.sorted().joined(separator: ", "))"
        }
        return Diagnostic(source: source, pattern: original,
                          issue: "pattern no longer matches any tool", suggestion: suggestion)
    }

    /// Diagnostics for the built-in and user-defined agents' `mcp_tools`
    /// fallback patterns (report only — those live in agent files, which are
    /// never rewritten).
    static func fallbackPatternDiagnostics(surface: MCPToolSurface) -> [Diagnostic] {
        var out: [Diagnostic] = []
        let config = loadConfigIfNeeded()
        for sub in SubagentTypes.all() {
            guard let patterns = sub.mcpToolPatterns, !patterns.isEmpty else { continue }
            // A routing-file entry overrides the fallback; skip agents that have one.
            if config[sub.name] != nil || caseMatchedAgentKey(sub.name, in: config) != nil { continue }
            for pattern in patterns {
                let canonical = canonicalPattern(pattern, surface: surface)
                if let diagnostic = diagnose(canonical, original: pattern, source: "mcp_tools \(sub.name)", surface: surface) {
                    out.append(diagnostic)
                }
            }
        }
        return out
    }

    /// Persisted-route migration: idempotent, rewrites only when a route
    /// changed, records diagnostics for doctor. Called once per turn from
    /// `refreshFromRegistry()`.
    static func migrateRoutingFile(surface: MCPToolSurface) {
        let config = loadConfigIfNeeded()
        let result = canonicalized(config, surface: surface)
        if result.changed {
            do {
                try save(config: result.config)
                DebugTelemetry.log(.toolStart, summary: "mcp routing migrated to canonical aliases",
                                   detail: routingURL().path)
            } catch {
                DebugTelemetry.log(.toolError, summary: "mcp routing migration failed",
                                   detail: String(describing: error), isError: true)
            }
        }
        let diagnostics = result.diagnostics + fallbackPatternDiagnostics(surface: surface)
        persistDiagnostics(diagnostics)
    }

    /// Diagnostics file read by `briglia doctor` (a separate process that
    /// never spawns MCP servers itself).
    static func diagnosticsURL() -> URL {
        StoragePaths.dataRoot.appendingPathComponent("mcp-routing-diagnostics.json")
    }

    private struct DiagnosticsFile: Codable {
        let generatedAt: Date
        let diagnostics: [Diagnostic]
    }

    private static func persistDiagnostics(_ diagnostics: [Diagnostic]) {
        cacheLock.lock()
        let unchanged = lastPersistedDiagnostics == diagnostics
        if !unchanged { lastPersistedDiagnostics = diagnostics }
        cacheLock.unlock()
        if unchanged { return }
        let file = DiagnosticsFile(generatedAt: Date(), diagnostics: diagnostics)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(file) else { return }
        let url = diagnosticsURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Doctor lines: last recorded diagnostics plus a sync charset check of
    /// the routing file (no registry needed).
    static func doctorFindings() -> [(text: String, problem: Bool)] {
        var out: [(String, Bool)] = []
        let config = loadConfigIfNeeded()
        for agent in config.keys.sorted() {
            guard let routing = config[agent] else { continue }
            for (list, kind) in [(routing.always, "always"), (routing.deferred, "deferred")] {
                for pattern in list where !isValidPattern(pattern) {
                    out.append(("mcp-routing.json \(agent).\(kind): pattern '\(pattern)' uses characters outside [A-Za-z0-9_.-] and is ignored", true))
                }
            }
        }
        let url = diagnosticsURL()
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let file = try? decoder.decode(DiagnosticsFile.self, from: data) {
                for d in file.diagnostics {
                    var line = "\(d.source): '\(d.pattern)' — \(d.issue)"
                    if let s = d.suggestion { line += " (\(s))" }
                    out.append((line, false))
                }
                if file.diagnostics.isEmpty {
                    out.append(("MCP routing: every route resolves to a connected tool (checked \(file.generatedAt))", false))
                }
            }
        } else {
            out.append(("MCP routing: no diagnostics recorded yet (the daemon writes them at each turn)", false))
        }
        return out
    }

    // MARK: - Config loading

    private static func loadConfigIfNeeded() -> [String: AgentRouting] {
        cacheLock.lock()
        if let cached = cachedConfig {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let loaded = loadFromDisk() ?? [:]
        cacheLock.lock()
        cachedConfig = loaded
        cacheLock.unlock()
        return loaded
    }

    private static func loadFromDisk() -> [String: AgentRouting]? {
        let url = routingURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: AgentRouting] = [:]
        for (agent, raw) in root {
            if let list = raw as? [String] {
                // Backward compat: plain array → always
                out[agent] = AgentRouting(always: list, deferred: [])
            } else if let obj = raw as? [String: Any] {
                // New format: { "always": [...], "deferred": [...] }
                let always = (obj["always"] as? [String]) ?? []
                let deferred = (obj["deferred"] as? [String]) ?? []
                out[agent] = AgentRouting(always: always, deferred: deferred)
            }
        }
        return out
    }

    /// Agent names in mcp-routing.json may come in with exact built-in
    /// capitalization (`Browse`). When a caller asks for a lowercase
    /// variant (or vice versa), attempt a case-insensitive match before
    /// giving up.
    private static func caseMatchedAgentKey(_ agent: String, in config: [String: AgentRouting]) -> String? {
        let lowered = agent.lowercased()
        return config.keys.first { $0.lowercased() == lowered }
    }

    static func routingURL() -> URL {
        StoragePaths.configRoot
            .appendingPathComponent("mcp-routing.json")
    }
}
