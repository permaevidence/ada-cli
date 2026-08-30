import Foundation

/// Per-agent MCP tool routing.
///
/// Phase 2 of the MCP subsystem. Decides which MCP-backed tools each agent
/// (main, built-in subagents, user-defined subagents) is allowed to see in
/// its prompt tool block, and whether those tools are loaded **always**
/// (in the tools array every turn) or **deferred** (discoverable on-demand
/// via `tool_search` + `mcp_call`).
///
/// The routing file lives at `~/.config/ada/mcp-routing.json`:
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
/// Each entry is a list of patterns matching prefixed tool names
/// (`mcp__<server>__<tool>`). Supported pattern shapes:
///   - Exact full name:                `"mcp__playwright__browser_click"`
///   - Trailing-wildcard (server-wide): `"mcp__playwright__*"`
///   - Double wildcard:                `"mcp__*"` (every MCP — escape hatch)
///
/// If an agent has no entry in the file, the subagent's `mcpToolPatterns`
/// (set on `SubagentType`) are used as a fallback (always mode).
/// Main agent always falls back to empty.
///
/// The routing file is loaded lazily on first query and cached in-process.
/// `reload()` forces a re-read (used after Settings UI writes in Phase 3).
enum MCPAgentRouting {

    // MARK: - Per-agent routing entry

    /// Parsed routing for a single agent: which MCP patterns are always-loaded
    /// and which are deferred (on-demand via tool_search/mcp_call).
    struct AgentRouting {
        var always: [String]
        var deferred: [String]

        var isEmpty: Bool { always.isEmpty && deferred.isEmpty }
        /// All patterns combined (used when an agent should see everything directly).
        var allPatterns: [String] { always + deferred }
    }

    // MARK: - Cached state

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedConfig: [String: AgentRouting]?
    nonisolated(unsafe) private static var cachedInstalledServers: Set<String> = []
    nonisolated(unsafe) private static var cachedMCPToolNames: Set<String> = []

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

    /// Returns the set of MCP server names that are **deferred** for `agent`.
    /// ConversationManager uses this to fetch summaries for the system prompt.
    static func deferredServers(
        forAgent agent: String,
        allTools: [ToolDefinition],
        fallbackPatterns: [String]?
    ) -> Set<String> {
        let routing = resolveRouting(forAgent: agent, fallbackPatterns: fallbackPatterns)
        let patterns = routing.deferred
        if patterns.isEmpty { return [] }

        // Find all tools matching deferred patterns, extract unique server names
        var servers: Set<String> = []
        for tool in allTools {
            if patterns.contains(where: { matches(pattern: $0, name: tool.function.name) }) {
                if let (server, _) = MCPRegistry.splitPrefixedName(tool.function.name) {
                    servers.insert(server)
                }
            }
        }
        return servers
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
    /// default.
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

    /// Sync-readable snapshot of MCP servers known to the registry at the
    /// most recent `refreshFromRegistry()` call. Used by `SubagentTypes.all()`
    /// to decide whether to register the Browse built-in (it only appears
    /// when their backing MCP is actually installed).
    static func installedServers() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedInstalledServers
    }

    /// Sync-readable list of currently-advertised MCP tool names (prefixed).
    /// Populated by `refreshFromRegistry()`.
    static func currentToolNames() -> Set<String> {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedMCPToolNames
    }

    /// Pull fresh state from the registry and update the sync caches.
    /// ConversationManager calls this at the top of every turn, just before
    /// assembling the tool list, so sync consumers (SubagentTypes.all() et al)
    /// see up-to-date state without needing their own async path.
    static func refreshFromRegistry() async {
        let status = await MCPRegistry.shared.status()
        let tools = await MCPRegistry.shared.allToolDefinitions()
        let installed = Set(status.filter { $0.connected && !$0.failed }.map { $0.name })
        let toolNames = Set(tools.map { $0.function.name })
        setRegistryCache(installed: installed, toolNames: toolNames)
    }

    /// Sync shim for updating the cache — keeps the lock manipulation out
    /// of the async `refreshFromRegistry()` body.
    private static func setRegistryCache(installed: Set<String>, toolNames: Set<String>) {
        cacheLock.lock()
        cachedInstalledServers = installed
        cachedMCPToolNames = toolNames
        cacheLock.unlock()
    }

    /// Force re-read of the routing JSON on next access. Call after Settings
    /// UI writes the file.
    static func reload() {
        cacheLock.lock()
        cachedConfig = nil
        cacheLock.unlock()
    }

    /// Write the full routing config to disk. Used by Settings UI.
    static func save(config: [String: AgentRouting]) throws {
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
    /// the file is missing). Useful for the Settings UI to populate its state.
    static func currentConfig() -> [String: AgentRouting] {
        return loadConfigIfNeeded()
    }

    // MARK: - Pattern matching

    /// Match `name` against `pattern`. Supported shapes:
    ///   - Exact:        "mcp__playwright__browser_click"
    ///   - Suffix glob:  "mcp__playwright__*"
    ///   - Broad glob:   "mcp__*"
    static func matches(pattern: String, name: String) -> Bool {
        if pattern == name { return true }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            return name.hasPrefix(prefix)
        }
        return false
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

    private static func routingURL() -> URL {
        StoragePaths.configRoot
            .appendingPathComponent("mcp-routing.json")
    }
}
