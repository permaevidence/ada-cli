import Foundation

/// Read/write helpers for user-defined subagent `.md` files.
///
/// The disk format is the same YAML-frontmatter shape that
/// `UserAgentLoader` consumes — see `UserAgentLoader.swift` header for
/// field docs. This enum adds the serializer and file operations the
/// Settings UI needs.
enum SubagentSerializer {

    static func agentsDirectory() -> URL {
        StoragePaths.configRoot
            .appendingPathComponent("agents", isDirectory: true)
    }

    static func fileURL(forName name: String) -> URL {
        agentsDirectory().appendingPathComponent("\(sanitizeFilename(name)).md", isDirectory: false)
    }

    static func listUserDefinedFiles() -> [URL] {
        let dir = agentsDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Serialize a subagent definition to YAML-frontmatter + body markdown.
    /// The resulting file round-trips through `UserAgentLoader.loadAll()`.
    static func encode(
        name: String,
        description: String,
        systemPrompt: String,
        nativeTools: [String]?,
        mcpToolPatterns: [String]?,
        model: String,     // "inherit" | "cheap-vision" | "cheap-text"
        maxTurns: Int
    ) -> String {
        var lines: [String] = ["---"]
        lines.append("name: \(yamlScalar(name))")
        lines.append("description: \(yamlScalar(description))")

        if let tools = nativeTools, !tools.isEmpty {
            lines.append("tools:")
            for t in tools.sorted() { lines.append("  - \(t)") }
        }
        if let patterns = mcpToolPatterns, !patterns.isEmpty {
            lines.append("mcp_tools:")
            for p in patterns { lines.append("  - \(p)") }
        }
        lines.append("model: \(model)")
        lines.append("max_turns: \(maxTurns)")
        lines.append("---")
        lines.append("")
        lines.append(systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Write a subagent `.md` file atomically.
    static func save(
        name: String,
        description: String,
        systemPrompt: String,
        nativeTools: [String]?,
        mcpToolPatterns: [String]?,
        model: String,
        maxTurns: Int
    ) throws {
        let content = encode(
            name: name,
            description: description,
            systemPrompt: systemPrompt,
            nativeTools: nativeTools,
            mcpToolPatterns: mcpToolPatterns,
            model: model,
            maxTurns: maxTurns
        )
        let url = fileURL(forName: name)
        try PrivateStorage.ensureDirectory(agentsDirectory())
        try PrivateStorage.writeAtomically(Data(content.utf8), to: url)
    }

    /// Delete a user-defined subagent file by its name.
    @discardableResult
    static func delete(name: String) -> Bool {
        let url = fileURL(forName: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Find a user-defined agent by name and return its parsed pieces so
    /// the editor can populate fields when editing. Returns nil for built-ins
    /// or missing files.
    static func loadForEditing(name: String) -> SubagentEditorDraft? {
        let candidate = fileURL(forName: name)
        guard FileManager.default.fileExists(atPath: candidate.path),
              let raw = try? String(contentsOf: candidate, encoding: .utf8) else {
            return nil
        }
        return Self.parseForEditing(raw)
    }

    /// Strip quotes if the user provided a quoted scalar, return the value
    /// otherwise. Used to avoid double-wrapping on round-trip.
    private static func yamlScalar(_ s: String) -> String {
        // If the string has YAML-special characters (`: # - [ ] { } & * !`),
        // emit it quoted. Otherwise plain.
        let dangerous: Set<Character> = [":", "#", "-", "[", "]", "{", "}", "&", "*", "!", ",", "?", "|", ">", "\""]
        if s.contains(where: { dangerous.contains($0) }) {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    /// Replace characters that aren't valid in a kebab-case filename.
    /// Matches the "kebab-case" convention UserAgentLoader documents.
    static func sanitizeFilename(_ raw: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var out = ""
        var lastWasDash = false
        for ch in raw {
            if allowed.contains(ch) {
                out.append(ch)
                lastWasDash = (ch == "-" || ch == "_")
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    // MARK: - Parse back for editing

    /// Minimal round-trip parser used ONLY by the editor to pre-populate
    /// fields. `UserAgentLoader.parseFrontmatter` is private; this duplicates
    /// just enough of that logic to be independent. Fields we don't care about
    /// (unknown keys) are ignored.
    /// Internal (not fileprivate) so the lane selftest can verify this parse
    /// stays aligned with UserAgentLoader's runtime parse.
    static func parseForEditing(_ raw: String) -> SubagentEditorDraft? {
        let lines = raw.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }
        var frontmatterEnd = -1
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                frontmatterEnd = i
                break
            }
        }
        guard frontmatterEnd > 0 else { return nil }
        let fmLines = Array(lines[1..<frontmatterEnd])
        let bodyLines = Array(lines[(frontmatterEnd + 1)..<lines.count])

        var name = ""
        var description = ""
        var tools: [String]? = nil
        var mcpTools: [String]? = nil
        var model = "inherit"
        var maxTurns = 150

        var i = 0
        while i < fmLines.count {
            let line = fmLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if rawValue.isEmpty {
                var items: [String] = []
                var j = i + 1
                while j < fmLines.count {
                    let nextTrim = fmLines[j].trimmingCharacters(in: .whitespaces)
                    if nextTrim.hasPrefix("- ") {
                        items.append(String(nextTrim.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                        j += 1
                    } else { break }
                }
                switch key {
                case "tools": tools = items
                case "mcp_tools": mcpTools = items
                default: break
                }
                i = j
            } else {
                let value = stripQuotes(rawValue)
                switch key {
                case "name": name = value
                case "description": description = value
                case "tools":
                    tools = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case "mcp_tools":
                    mcpTools = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                case "model":
                    // Mirrors UserAgentLoader: the retired cheapFast value is
                    // no longer recognized — like any unknown value it shows
                    // (and re-saves) as inherit, matching what the runtime
                    // actually does with the file.
                    switch value.lowercased() {
                    case "cheap-vision", "cheap_vision", "cheapvision":
                        model = "cheap-vision"
                    case "cheap-text", "cheap_text", "cheaptext":
                        model = "cheap-text"
                    default:
                        model = "inherit"
                    }
                case "max_turns": if let n = Int(value), n > 0 { maxTurns = n }
                default: break
                }
                i += 1
            }
        }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return SubagentEditorDraft(
            name: name,
            description: description,
            systemPrompt: body,
            nativeTools: tools,
            mcpToolPatterns: mcpTools,
            model: model,
            maxTurns: maxTurns
        )
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// Loaded editor state for a user-defined subagent. Populates the Settings
/// editor sheet when the user clicks "Edit" on an existing agent.
struct SubagentEditorDraft {
    var name: String
    var description: String
    var systemPrompt: String
    var nativeTools: [String]?
    var mcpToolPatterns: [String]?
    var model: String     // "inherit" | "cheap-vision" | "cheap-text"
    var maxTurns: Int

    static func blank() -> SubagentEditorDraft {
        SubagentEditorDraft(
            name: "",
            description: "",
            systemPrompt: "",
            nativeTools: nil,
            mcpToolPatterns: nil,
            model: "inherit",
            maxTurns: 150
        )
    }
}

/// Scaffolded starting points for the "New Agent" flow.
enum SubagentTemplates {
    struct Template: Identifiable {
        let id: String
        let displayName: String
        let draft: SubagentEditorDraft
    }

    static let all: [Template] = [
        Template(
            id: "custom",
            displayName: "Custom (blank)",
            draft: SubagentEditorDraft.blank()
        ),
        Template(
            id: "browser",
            displayName: "Browser use (Playwright)",
            draft: SubagentEditorDraft(
                name: "browser-use",
                description: "Drives a browser via Playwright MCP to navigate, snapshot, click, and extract data.",
                systemPrompt:
                    "You are a browser automation specialist. Use the mcp__playwright__* tools to navigate, snapshot, click, type, and evaluate pages. Prefer `browser_snapshot` over `browser_take_screenshot` unless a visual is specifically requested — it's cheaper and more structured. When handing results back, include what you navigated to, what you interacted with, and any extracted text verbatim. If a site asks to log in or looks sensitive (banking, admin), stop and report back rather than acting.",
                nativeTools: ["read_file", "grep", "bash", "web_fetch", "inspect_media"],
                mcpToolPatterns: ["mcp__playwright__*"],
                model: "inherit",
                maxTurns: 25
            )
        ),
        Template(
            id: "research",
            displayName: "Research analyst",
            draft: SubagentEditorDraft(
                name: "research-analyst",
                description: "Reads broadly and returns findings with verbatim quotes and citations.",
                systemPrompt:
                    "You are a read-only research analyst. Gather information from the codebase and the web, then return a structured report with quotes, file paths, and URLs. Do not modify files. Prioritize accuracy over speed — verify claims with two sources when possible. Output as bullet points under short headers, ending with a 'Confidence' line (high/medium/low) per claim.",
                nativeTools: ["read_file", "grep", "glob", "list_dir", "lsp", "web_search", "web_fetch", "inspect_media"],
                mcpToolPatterns: nil,
                model: "inherit",
                maxTurns: 20
            )
        ),
        Template(
            id: "planner",
            displayName: "Implementation planner",
            draft: SubagentEditorDraft(
                name: "implementation-planner",
                description: "Designs a step-by-step plan with critical files, sequencing, and risks.",
                systemPrompt:
                    "You are a software architect. Read relevant code, then return a sequenced plan: (1) goal, (2) files to touch with brief why, (3) order of operations, (4) risks + rollback, (5) verification steps. Do not modify files. Be concrete — no hand-waving like 'then handle errors'.",
                nativeTools: ["read_file", "grep", "glob", "list_dir", "list_recent_files", "lsp", "web_fetch", "web_search", "inspect_media"],
                mcpToolPatterns: nil,
                model: "inherit",
                maxTurns: 20
            )
        ),
        Template(
            id: "sql",
            displayName: "SQL analyst",
            draft: SubagentEditorDraft(
                name: "sql-analyst",
                description: "Inspects SQL schemas and runs read queries via the postgres/sqlite/mysql MCP.",
                systemPrompt:
                    "You are a database analyst. Use the mcp__postgres__*, mcp__sqlite__*, or mcp__mysql__* tools (whichever are present) to list schemas, inspect tables, and run read queries. For destructive writes (INSERT/UPDATE/DELETE/DROP), stop and confirm intent before executing. Return results as concise summaries with row counts and key values — do not dump entire tables verbatim.",
                nativeTools: ["read_file", "grep", "bash", "inspect_media"],
                mcpToolPatterns: ["mcp__postgres__*", "mcp__sqlite__*", "mcp__mysql__*"],
                model: "inherit",
                maxTurns: 20
            )
        ),
        Template(
            id: "code-reviewer",
            displayName: "Code reviewer",
            draft: SubagentEditorDraft(
                name: "code-reviewer",
                description: "Reviews a diff or file for bugs, security issues, and clarity concerns.",
                systemPrompt:
                    "You are a code reviewer. Read the specified diff or file(s), identify concrete issues (bugs, security vulnerabilities, unclear names, missing edge cases, poor error handling). For each finding: cite the file:line, describe the issue, and suggest a fix. Skip style nits unless they meaningfully hurt readability. End with a one-line summary verdict: 'LGTM', 'minor issues', or 'blocking issues'.",
                nativeTools: ["read_file", "grep", "glob", "list_dir", "lsp", "bash", "inspect_media"],
                mcpToolPatterns: nil,
                model: "inherit",
                maxTurns: 15
            )
        )
    ]
}
