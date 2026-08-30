import Foundation

// MARK: - User-Defined Subagent Loader
//
// Scans `~/.config/ada/agents/*.md` for user-defined subagent definitions.
// Each file must begin with a YAML frontmatter block (`---` delimited) with
// these fields:
//   name: kebab-case-name         (required)
//   description: one-line text    (required)
//   tools: read_file, grep, bash  (optional — comma list or YAML list form)
//   mcp_tools:                    (optional — MCP tool-name patterns this agent can see;
//     - mcp__playwright__*        supports exact names or trailing-wildcard globs)
//     - mcp__github__*
//   model: inherit | cheap-vision | cheap-text   (optional, default inherit;
//     lanes are the user-configured /subagentmodels picks — the retired
//     cheapFast value is no longer recognized: it inherits, with a warning)
//   max_turns: 200                (optional, default 200)
// The body after the closing `---` is the agent's systemPromptSuffix.

enum UserAgentLoader {
    /// Scans the user-agents directory and returns parsed subagent types.
    /// Malformed files are logged to stderr and skipped.
    static func loadAll() -> [SubagentType] {
        let dir = agentsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var agents: [SubagentType] = []
        for url in entries where url.pathExtension.lowercased() == "md" {
            if let agent = parseFile(at: url) {
                agents.append(agent)
                FileHandle.standardError.write(
                    Data("[UserAgentLoader] loaded subagent '\(agent.name)' from \(url.path)\n".utf8)
                )
            }
        }
        return agents
    }

    // MARK: - Internals

    private static func agentsDirectory() -> URL {
        StoragePaths.configRoot
            .appendingPathComponent("agents", isDirectory: true)
    }

    private static func parseFile(at url: URL) -> SubagentType? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            logSkip(url, reason: "unreadable")
            return nil
        }

        guard let (frontmatter, body) = splitFrontmatter(raw) else {
            logSkip(url, reason: "missing or malformed frontmatter (expected leading `---` block)")
            return nil
        }

        let fields = parseFrontmatter(frontmatter)

        guard let name = fields["name"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            logSkip(url, reason: "missing required `name`")
            return nil
        }
        guard let description = fields["description"]?.stringValue?.trimmingCharacters(in: .whitespaces),
              !description.isEmpty else {
            logSkip(url, reason: "missing required `description`")
            return nil
        }

        let allowedTools: Set<String>?
        if let toolsValue = fields["tools"] {
            let list = toolsValue.listValue()
            allowedTools = list.isEmpty ? nil : Set(list)
        } else {
            allowedTools = nil
        }

        let mcpPatterns: [String]?
        if let mcpValue = fields["mcp_tools"] {
            let list = mcpValue.listValue()
            mcpPatterns = list.isEmpty ? nil : list
        } else {
            mcpPatterns = nil
        }

        // Default to .inherit so subagents use the same model as the main
        // agent. `model: cheap-vision` / `model: cheap-text` route to the
        // user-configured cheap lanes (/subagentmodels). The retired
        // `cheapFast` value is no longer recognized — like any unknown
        // value it inherits, with a load-time warning naming the fix.
        let modelHint = (fields["model"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let preferredModel: SubagentModelChoice
        switch modelHint {
        case "cheap-vision", "cheap_vision", "cheapvision":
            preferredModel = .cheapVision
        case "cheap-text", "cheap_text", "cheaptext":
            preferredModel = .cheapText
        case "inherit", "":
            preferredModel = .inherit
        default:
            preferredModel = .inherit
            FileHandle.standardError.write(Data("[UserAgentLoader] WARNING: agent '\(fields["name"]?.stringValue ?? "?")' has unrecognized 'model: \(modelHint)' — valid values are inherit, cheap-vision, cheap-text. Running with 'inherit' (the full parent model).\n".utf8))
        }

        var maxTurns = 200
        if let raw = fields["max_turns"]?.stringValue?.trimmingCharacters(in: .whitespaces),
           let parsed = Int(raw), parsed > 0 {
            maxTurns = parsed
        }

        let suffix = body.trimmingCharacters(in: .whitespacesAndNewlines)

        return SubagentType(
            name: name,
            description: description,
            systemPromptSuffix: suffix,
            allowedToolNames: allowedTools,
            defaultMaxTurns: maxTurns,
            preferredModel: preferredModel,
            mcpToolPatterns: mcpPatterns
        )
    }

    private static func logSkip(_ url: URL, reason: String) {
        FileHandle.standardError.write(
            Data("[UserAgentLoader] skipping \(url.lastPathComponent): \(reason)\n".utf8)
        )
    }

    /// Splits raw file text into (frontmatter, body) when it begins with a `---` block.
    /// Returns nil if the file does not begin with a frontmatter block.
    private static func splitFrontmatter(_ raw: String) -> (String, String)? {
        let lines = raw.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        var frontmatterLines: [String] = []
        var bodyStart = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = i + 1
                break
            }
            frontmatterLines.append(lines[i])
        }
        guard bodyStart >= 0 else { return nil }
        let body = lines[bodyStart..<lines.count].joined(separator: "\n")
        return (frontmatterLines.joined(separator: "\n"), body)
    }

    /// Minimal line-based parser. Supports:
    ///   key: value
    ///   key:
    ///     - item
    ///     - item
    private static func parseFrontmatter(_ text: String) -> [String: FrontmatterValue] {
        var out: [String: FrontmatterValue] = [:]
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                i += 1
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rawValue.isEmpty {
                // Possibly a YAML list on following lines
                var items: [String] = []
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let nextTrim = next.trimmingCharacters(in: .whitespaces)
                    if nextTrim.hasPrefix("- ") {
                        items.append(String(nextTrim.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                        j += 1
                    } else if nextTrim.isEmpty {
                        j += 1
                        break
                    } else {
                        break
                    }
                }
                if !items.isEmpty {
                    out[key] = .list(items)
                    i = j
                    continue
                }
                out[key] = .string("")
            } else {
                out[key] = .string(stripQuotes(rawValue))
            }
            i += 1
        }
        return out
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    fileprivate enum FrontmatterValue {
        case string(String)
        case list([String])

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        func listValue() -> [String] {
            switch self {
            case .list(let items):
                return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case .string(let s):
                return s.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        }
    }
}
