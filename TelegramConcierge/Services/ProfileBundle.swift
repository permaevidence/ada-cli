import Foundation

/// Shareable Briglia profile bundle.
///
/// Captures the three pieces of user-editable MCP/agent state into a single
/// JSON file that can be dropped on another machine (or another user's
/// setup) to reproduce the configuration:
///
///   - `mcpServers`   — contents of ~/.config/briglia/mcp.json (server configs)
///   - `mcpRouting`   — contents of ~/.config/briglia/mcp-routing.json
///   - `agents`       — every ~/.config/briglia/agents/*.md file verbatim
///
/// Explicitly NOT included: Keychain-backed secret values. The bundle
/// carries `secretRefs` (the variable names) so the importer knows what
/// tokens to populate, but the values remain local. This is intentional —
/// bundles can be committed to git, emailed, or posted to chat without
/// leaking credentials.
enum ProfileBundle {

    static let currentVersion = 1
    static let fileExtension = "briglia-profile.json"
    /// Export names of the previous product identity — imported forever
    /// with unchanged content handling (rename plan §4.5.3).
    static let legacyFileExtensions = ["ada-profile.json"]
    static var acceptedFileExtensions: [String] { [fileExtension] + legacyFileExtensions }
    static func isProfileFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return acceptedFileExtensions.contains { lower.hasSuffix("." + $0) || lower == $0 }
    }

    // MARK: - Export

    /// Build a bundle from the current on-disk state and return the
    /// serialized JSON data.
    static func exportData() throws -> Data {
        var root: [String: Any] = [
            "version": currentVersion,
            "exportedAt": isoNow(),
            "exportedBy": "Briglia \(appVersion())"
        ]

        // mcp.json — re-encode from the struct list so we strip any extraneous
        // fields and produce a canonical sort order.
        let servers = MCPRegistry.loadConfigsFromDisk()
        var mcpServers: [String: Any] = [:]
        for cfg in servers {
            var dict: [String: Any] = [
                "command": cfg.command,
                "args": cfg.arguments
            ]
            if !cfg.environment.isEmpty { dict["env"] = cfg.environment }
            if cfg.disabled { dict["disabled"] = true }
            if !cfg.secretRefs.isEmpty { dict["secretRefs"] = cfg.secretRefs }
            if let desc = cfg.description, !desc.isEmpty { dict["description"] = desc }
            mcpServers[cfg.name] = dict
        }
        root["mcpServers"] = mcpServers

        // mcp-routing.json — serialize AgentRouting to JSON-compatible dicts.
        let routingConfig = MCPAgentRouting.currentConfig()
        var routingDict: [String: Any] = [:]
        for (agent, routing) in routingConfig {
            if routing.deferred.isEmpty {
                routingDict[agent] = routing.always
            } else {
                routingDict[agent] = ["always": routing.always, "deferred": routing.deferred]
            }
        }
        root["mcpRouting"] = routingDict

        // User-defined agents — ship each .md file verbatim so round-trips
        // preserve the full prompt body.
        let agentFiles = SubagentSerializer.listUserDefinedFiles()
        var agents: [[String: String]] = []
        for url in agentFiles {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            agents.append([
                "filename": url.lastPathComponent,
                "content": content
            ])
        }
        root["agents"] = agents

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    // MARK: - Import

    /// Summary returned from a successful import. Surfaced in the UI so the
    /// user can see what actually changed (merge policy: overwrite by name).
    struct ImportResult {
        let mcpServersAdded: [String]
        let mcpServersReplaced: [String]
        let routingEntriesReplaced: [String]
        let agentsAdded: [String]
        let agentsReplaced: [String]
        let secretsToPopulate: [(server: String, variable: String)]
        let warnings: [String]
    }

    /// Parse and apply a bundle. Merges — existing MCPs / agents / routing
    /// entries not mentioned in the bundle are left untouched. Entries that
    /// DO appear are overwritten.
    static func importData(_ data: Data) throws -> ImportResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ProfileBundle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bundle is not a JSON object"])
        }
        let version = (root["version"] as? Int) ?? 0
        guard version == currentVersion else {
            throw NSError(
                domain: "ProfileBundle",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported bundle version \(version). This build expects version \(currentVersion)."]
            )
        }

        var warnings: [String] = []

        // --- MCP servers ---
        var addedServers: [String] = []
        var replacedServers: [String] = []
        var secretsToPopulate: [(String, String)] = []

        let existingServers = MCPRegistry.loadConfigsFromDisk()
        var merged: [String: MCPServerConfig] = Dictionary(uniqueKeysWithValues: existingServers.map { ($0.name, $0) })

        if let bundled = root["mcpServers"] as? [String: Any] {
            for (name, raw) in bundled {
                guard let dict = raw as? [String: Any],
                      let command = dict["command"] as? String else {
                    warnings.append("Server '\(name)' in bundle is malformed — skipped.")
                    continue
                }
                let args = (dict["args"] as? [String]) ?? []
                let env = (dict["env"] as? [String: String]) ?? [:]
                let disabled = (dict["disabled"] as? Bool) ?? false
                let secretRefs = (dict["secretRefs"] as? [String]) ?? []
                let desc = dict["description"] as? String
                let cfg = MCPServerConfig(
                    name: name,
                    command: command,
                    arguments: args,
                    environment: env,
                    disabled: disabled,
                    secretRefs: secretRefs,
                    description: desc
                )
                if merged[name] != nil {
                    replacedServers.append(name)
                } else {
                    addedServers.append(name)
                }
                merged[name] = cfg
                for ref in secretRefs {
                    let key = "mcp_env_\(name)_\(ref)"
                    if (KeychainHelper.load(key: key) ?? "").isEmpty {
                        secretsToPopulate.append((name, ref))
                    }
                }
            }
            try MCPRegistry.saveConfigsToDisk(Array(merged.values))
        }

        // --- MCP routing ---
        var routingReplaced: [String] = []
        if let bundledRouting = root["mcpRouting"] as? [String: Any] {
            var current = MCPAgentRouting.currentConfig()
            for (agent, raw) in bundledRouting {
                let routing: MCPAgentRouting.AgentRouting
                if let list = raw as? [String] {
                    // Backward compat: plain array → always
                    routing = MCPAgentRouting.AgentRouting(always: list, deferred: [])
                } else if let obj = raw as? [String: Any] {
                    let always = (obj["always"] as? [String]) ?? []
                    let deferred = (obj["deferred"] as? [String]) ?? []
                    routing = MCPAgentRouting.AgentRouting(always: always, deferred: deferred)
                } else {
                    continue
                }
                if current[agent] != nil { routingReplaced.append(agent) }
                current[agent] = routing
            }
            try MCPAgentRouting.save(config: current)
        }

        // --- User-defined agents ---
        var agentsAdded: [String] = []
        var agentsReplaced: [String] = []
        if let bundledAgents = root["agents"] as? [[String: String]] {
            let dir = SubagentSerializer.agentsDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for entry in bundledAgents {
                guard let filename = entry["filename"], !filename.isEmpty,
                      let content = entry["content"] else { continue }
                // Keep just the base filename to avoid path traversal from
                // a malicious bundle.
                let sanitized = (filename as NSString).lastPathComponent
                guard sanitized.hasSuffix(".md") else {
                    warnings.append("Agent file '\(filename)' skipped (not a .md file).")
                    continue
                }
                let dest = dir.appendingPathComponent(sanitized, isDirectory: false)
                let existed = FileManager.default.fileExists(atPath: dest.path)
                try content.data(using: .utf8)?.write(to: dest, options: .atomic)
                if existed { agentsReplaced.append(sanitized) } else { agentsAdded.append(sanitized) }
            }
        }

        return ImportResult(
            mcpServersAdded: addedServers.sorted(),
            mcpServersReplaced: replacedServers.sorted(),
            routingEntriesReplaced: routingReplaced.sorted(),
            agentsAdded: agentsAdded.sorted(),
            agentsReplaced: agentsReplaced.sorted(),
            secretsToPopulate: secretsToPopulate,
            warnings: warnings
        )
    }

    // MARK: - Helpers

    private static func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
    }

    private static func appVersion() -> String {
        adaCLIVersion
    }

    static func defaultExportFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "briglia-profile-\(fmt.string(from: Date())).\(fileExtension)"
    }
}
