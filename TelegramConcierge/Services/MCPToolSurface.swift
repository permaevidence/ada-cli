import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MCP tool surface: the names, text and schemas the model sees for MCP-backed
// tools are Briglia-assigned and Briglia-validated, never the server's raw
// strings.
//
// Two levels of identity:
//   - a **server handle** per configured server (`MCPNaming.serverHandle`),
//   - a **tool alias** per accepted tool: `mcp__<handle>__<segment>`.
//
// Handles and segments are drawn from the provider-safe charset
// `[A-Za-z0-9_-]`, never contain `__` and never start or end with `_`, so the
// first `__` after the `mcp__` prefix always delimits the handle. That makes
// every alias unique per (server, tool), every alias parseable without a
// lookup, and every per-server wildcard `mcp__<handle>__*` exact: no other
// server's aliases can share that prefix. Every alias is at most 64
// characters by construction.
//
// Text the server controls (descriptions, fallback sentences, summaries)
// passes through `MarkerNeutralizer.escape`. Strings the model must echo back
// unchanged (property keys, `required` entries, enum values, `type`) are
// validated and never rewritten: a tool whose semantic strings carry the
// reserved marker prefix is refused.

// MARK: - Naming

enum MCPNaming {
    static let prefix = "mcp__"
    static let separator = "__"
    /// Provider function-name ceiling (`^[A-Za-z0-9_-]{1,64}$`).
    static let maxFunctionNameLength = 64
    /// `mcp__` (5) + `__` (2).
    static let fixedOverhead = 7
    /// `_` + 12 hex characters, reserved whether or not it is finally used.
    static let hashSuffixLength = 13
    /// Smallest readable tool fragment kept in front of a hash suffix.
    static let minToolFragment = 4
    /// 64 − 7 − 13 − 4.
    static let maxHandleLength = 40
    /// 40 − 13: the readable stem of a hashed handle.
    static let handleStemLength = 27

    static func isAllowedCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return true
        default: return false
        }
    }

    /// Charset-only check: every character in `[A-Za-z0-9_-]`, non-empty,
    /// within the provider length ceiling.
    static func isProviderSafeIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= maxFunctionNameLength else { return false }
        return s.unicodeScalars.allSatisfy(isAllowedCharacter)
    }

    /// A *clean* identifier can be used verbatim as a handle or segment: safe
    /// charset, no `__` run, and no leading/trailing `_` (the delimiter
    /// invariant that keeps aliases unambiguous and wildcards exact).
    static func isCleanIdentifier(_ s: String) -> Bool {
        guard isProviderSafeIdentifier(s) else { return false }
        if s.contains(separator) { return false }
        if s.hasPrefix("_") || s.hasSuffix("_") { return false }
        return true
    }

    /// Replace every character outside the safe charset with `_`.
    static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            out.append(isAllowedCharacter(scalar) ? scalar : "_")
        }
        return String(out)
    }

    /// First 12 hex characters of SHA-256 over the ORIGINAL name.
    static func hash12(_ original: String) -> String {
        let digest = SHA256.hash(data: Data(original.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// Readable stem for a hashed identifier: sanitized, `_` runs collapsed,
    /// edge `_` trimmed, truncated to `length`, trailing `_` trimmed again.
    /// Never empty (falls back to `fallback`).
    static func stem(_ original: String, length: Int, fallback: String) -> String {
        var collapsed = ""
        var previousUnderscore = false
        for ch in sanitize(original) {
            if ch == "_" {
                if previousUnderscore { continue }
                previousUnderscore = true
            } else {
                previousUnderscore = false
            }
            collapsed.append(ch)
        }
        var trimmed = Substring(collapsed)
        while trimmed.first == "_" { trimmed = trimmed.dropFirst() }
        while trimmed.last == "_" { trimmed = trimmed.dropLast() }
        var cut = Substring(trimmed.prefix(max(length, 1)))
        while cut.last == "_" { cut = cut.dropLast() }
        return cut.isEmpty ? fallback : String(cut)
    }

    /// Server handle (plan §H1.2): the server name itself when it is clean and
    /// at most 40 characters; otherwise a 27-character stem plus `_` and 12
    /// hex characters of SHA-256 over the original name. Always ≤ 40 and
    /// always clean.
    static func serverHandle(for serverName: String) -> String {
        if isCleanIdentifier(serverName), serverName.count <= maxHandleLength {
            return serverName
        }
        return stem(serverName, length: handleStemLength, fallback: "srv") + "_" + hash12(serverName)
    }

    /// Budget left for the tool segment once `handle` is embedded.
    static func segmentBudget(handle: String) -> Int {
        maxFunctionNameLength - (prefix.count + handle.count + separator.count)
    }

    /// Tool segment: the tool name itself when clean and within budget;
    /// otherwise a stem of `budget − 13` characters plus `_` and 12 hex
    /// characters of SHA-256 over the original tool name.
    static func toolSegment(for toolName: String, handle: String) -> String {
        let budget = segmentBudget(handle: handle)
        if isCleanIdentifier(toolName), toolName.count <= budget {
            return toolName
        }
        let stemLength = max(budget - hashSuffixLength, minToolFragment)
        return stem(toolName, length: stemLength, fallback: "tool") + "_" + hash12(toolName)
    }

    static func alias(handle: String, segment: String) -> String {
        prefix + handle + separator + segment
    }

    static func toolAlias(handle: String, toolName: String) -> String {
        alias(handle: handle, segment: toolSegment(for: toolName, handle: handle))
    }

    /// Wildcard pattern that selects exactly one server's tools.
    static func serverWildcard(handle: String) -> String {
        prefix + handle + separator + "*"
    }

    static func isValidHandle(_ handle: String) -> Bool {
        isCleanIdentifier(handle) && handle.count <= maxHandleLength
    }

    static func isValidAlias(_ alias: String) -> Bool {
        guard isProviderSafeIdentifier(alias), let parts = splitAlias(alias) else { return false }
        return isValidHandle(parts.handle) && isCleanIdentifier(parts.segment)
    }

    /// Split `mcp__<handle>__<segment>` at the first `__` after the prefix.
    /// Sound because handles never contain `__` and never end with `_`.
    static func splitAlias(_ alias: String) -> (handle: String, segment: String)? {
        guard alias.hasPrefix(prefix) else { return nil }
        let body = alias.dropFirst(prefix.count)
        guard let range = body.range(of: separator) else { return nil }
        let handle = String(body[..<range.lowerBound])
        let segment = String(body[range.upperBound...])
        guard !handle.isEmpty, !segment.isEmpty else { return nil }
        return (handle, segment)
    }

    /// Legacy raw name (`mcp__<server>__<tool>`), as advertised before the
    /// two-level identity. Kept only as a reverse-map key.
    static func legacyRawName(serverName: String, toolName: String) -> String {
        prefix + serverName + separator + toolName
    }
}

// MARK: - Schema validation and conversion

enum MCPSchemaValidation {
    static let allowedTypes: Set<String> = ["string", "number", "integer", "boolean", "object", "array"]

    enum Outcome {
        case accepted(ToolDefinition)
        case refused(reason: String)
    }

    /// Convert a server tool to the definition the model sees. Non-semantic
    /// text is escaped; semantic strings are validated and never rewritten.
    static func convert(_ tool: MCPTool, alias: String, serverHandle: String) -> Outcome {
        let prefix = MarkerNeutralizer.reservedPrefix
        let schema = tool.inputSchema
        let rawProps = (schema["properties"] as? [String: Any]) ?? [:]
        let required = (schema["required"] as? [String]) ?? []

        for key in required where key.contains(prefix) {
            return .refused(reason: "required entry carries the reserved marker prefix")
        }
        if let semanticProblem = semanticProblem(inProperties: rawProps, depth: 0) {
            return .refused(reason: semanticProblem)
        }

        var properties: [String: ParameterProperty] = [:]
        for (key, raw) in rawProps {
            guard let dict = raw as? [String: Any] else { continue }
            let type = normalizedType(dict["type"])
            var description = MarkerNeutralizer.escape((dict["description"] as? String) ?? "")
            var enumValues: [String]? = nil
            if let vals = dict["enum"] as? [Any] {
                enumValues = vals.map { v -> String in
                    if let s = v as? String { return s }
                    return String(describing: v)
                }
            }
            var itemsSchema: ArrayItemsSchema? = nil
            switch type {
            case "array":
                if let items = dict["items"] as? [String: Any] {
                    itemsSchema = ArrayItemsSchema(type: normalizedType(items["type"]))
                } else {
                    itemsSchema = ArrayItemsSchema(type: "string")
                }
            case "object":
                // Flatten: note the sub-shape in the description so the model
                // can still form valid arguments. Keys are validated above.
                if let sub = dict["properties"] as? [String: Any], !sub.isEmpty {
                    let keys = sub.keys.sorted().joined(separator: ", ")
                    let note = MarkerNeutralizer.escape("JSON object with fields: \(keys)")
                    description = description.isEmpty ? note : "\(description) (\(note))"
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
            fullDescription = MarkerNeutralizer.escape("Tool provided by MCP server '\(serverHandle)'.")
        } else {
            fullDescription = MarkerNeutralizer.escape("\(tool.description)\n\n(Provided by MCP server '\(serverHandle)'.)")
        }

        return .accepted(ToolDefinition(
            function: FunctionDefinition(
                name: alias,
                description: fullDescription,
                parameters: FunctionParameters(properties: properties, required: required)
            )
        ))
    }

    /// `type` strings outside the JSON-Schema primitive set fall back to
    /// `string`; a `type` carrying the reserved prefix is caught by
    /// `semanticProblem` before conversion.
    static func normalizedType(_ raw: Any?) -> String {
        guard let s = raw as? String, allowedTypes.contains(s) else { return "string" }
        return s
    }

    /// Returns a reason when any meaning-bearing string (property key, nested
    /// field key, enum value, `type`, `required` entry) carries the reserved
    /// prefix. Bounded recursion over nested object schemas.
    static func semanticProblem(inProperties props: [String: Any], depth: Int) -> String? {
        let prefix = MarkerNeutralizer.reservedPrefix
        guard depth < 8 else { return nil }
        for (key, raw) in props {
            if key.contains(prefix) { return "property key carries the reserved marker prefix" }
            guard let dict = raw as? [String: Any] else { continue }
            if let type = dict["type"] as? String, type.contains(prefix) {
                return "type string carries the reserved marker prefix"
            }
            if let vals = dict["enum"] as? [Any] {
                for v in vals {
                    let s = (v as? String) ?? String(describing: v)
                    if s.contains(prefix) { return "enum value carries the reserved marker prefix" }
                }
            }
            if let items = dict["items"] as? [String: Any],
               let itemType = items["type"] as? String, itemType.contains(prefix) {
                return "items type carries the reserved marker prefix"
            }
            if let nestedRequired = dict["required"] as? [String] {
                for key in nestedRequired where key.contains(prefix) {
                    return "nested required entry carries the reserved marker prefix"
                }
            }
            if let sub = dict["properties"] as? [String: Any],
               let problem = semanticProblem(inProperties: sub, depth: depth + 1) {
                return problem
            }
        }
        return nil
    }
}

// MARK: - Accepted-tool registry

/// Canonical registry of the tools the model may see and call, rebuilt from
/// the connected servers' `tools/list`. Every consumer — direct dispatch,
/// deferred routing, `tool_search`, `mcp_call`, prompt summaries — resolves
/// through this value, never through string parsing of the wire name.
struct MCPToolSurface {

    /// Release A ships a one-release grace for legacy raw names
    /// (`mcp__<server>__<tool>`): they resolve only through the validated
    /// reverse map, and only when exactly one accepted tool owns them.
    /// Release B flips this to `false`; raw names are then refused.
    static let legacyRawNameGraceEnabled = true

    struct AcceptedTool {
        let alias: String
        let serverName: String
        let serverHandle: String
        let toolName: String
        let description: String        // original, unescaped (never rendered directly)
        let definition: ToolDefinition // escaped/validated, what the model sees
    }

    struct Refusal {
        let serverName: String
        let toolName: String
        let reason: String
    }

    struct Server {
        let name: String
        let handle: String
        let configuredDescription: String?
        var aliases: [String]
    }

    enum Resolution {
        case tool(AcceptedTool)
        case unknown
        /// A legacy raw name owned by more than one accepted tool.
        case ambiguous([String])
        case legacyRefused
    }

    private(set) var servers: [String: Server] = [:]          // handle → server
    private(set) var handleByServerName: [String: String] = [:]
    private(set) var tools: [String: AcceptedTool] = [:]      // alias → tool
    private(set) var legacyReverse: [String: [String]] = [:]  // raw → aliases
    private(set) var refusals: [Refusal] = []
    private(set) var refusedServers: [String] = []

    static let empty = MCPToolSurface()

    /// Deterministic: servers and tools are processed in sorted order so a
    /// residual collision always refuses the same later entry.
    static func build(servers input: [(config: MCPServerConfig, tools: [MCPTool])]) -> MCPToolSurface {
        var surface = MCPToolSurface()
        let sorted = input.sorted { $0.config.name < $1.config.name }
        for (config, tools) in sorted {
            let handle = MCPNaming.serverHandle(for: config.name)
            guard MCPNaming.isValidHandle(handle), surface.servers[handle] == nil else {
                // Residual handle collision (or an unexpected invalid handle):
                // refuse the later server entirely — its tools would be
                // indistinguishable from the earlier server's.
                surface.refusedServers.append(config.name)
                surface.refusals.append(Refusal(serverName: config.name, toolName: "*",
                                                reason: "server handle '\(handle)' collides with another server"))
                continue
            }
            var server = Server(name: config.name, handle: handle,
                                configuredDescription: config.description, aliases: [])
            surface.handleByServerName[config.name] = handle
            for tool in tools.sorted(by: { $0.toolName < $1.toolName }) {
                let alias = MCPNaming.toolAlias(handle: handle, toolName: tool.toolName)
                guard MCPNaming.isValidAlias(alias), surface.tools[alias] == nil else {
                    surface.refusals.append(Refusal(serverName: config.name, toolName: tool.toolName,
                                                    reason: "alias '\(alias)' collides with an accepted tool"))
                    continue
                }
                switch MCPSchemaValidation.convert(tool, alias: alias, serverHandle: handle) {
                case .refused(let reason):
                    surface.refusals.append(Refusal(serverName: config.name, toolName: tool.toolName, reason: reason))
                case .accepted(let definition):
                    let accepted = AcceptedTool(alias: alias, serverName: config.name, serverHandle: handle,
                                                toolName: tool.toolName, description: tool.description,
                                                definition: definition)
                    surface.tools[alias] = accepted
                    server.aliases.append(alias)
                    let raw = MCPNaming.legacyRawName(serverName: config.name, toolName: tool.toolName)
                    surface.legacyReverse[raw, default: []].append(alias)
                }
            }
            surface.servers[handle] = server
        }
        return surface
    }

    // MARK: Queries

    var sortedDefinitions: [ToolDefinition] {
        tools.keys.sorted().compactMap { tools[$0]?.definition }
    }

    var sortedAliases: [String] { tools.keys.sorted() }

    func server(handle: String) -> Server? { servers[handle] }

    func handle(forServerName name: String) -> String? { handleByServerName[name] }

    /// Alias → handle, sound by construction (no lookup needed), but only for
    /// registered aliases.
    func serverHandle(forAlias alias: String) -> String? { tools[alias]?.serverHandle }

    /// Resolve a wire name the model sent: canonical alias first; then, under
    /// the grace flag, a legacy raw name through the validated reverse map.
    func resolve(name: String) -> Resolution {
        if let tool = tools[name] { return .tool(tool) }
        return resolveLegacy(rawName: name)
    }

    /// Resolve an `mcp_call(server:, tool:)` pair. `server` must be a handle;
    /// `tool` may be the full alias (must belong to that handle) or the tool
    /// segment. Under the grace flag the pair may also be the legacy raw
    /// (server name, tool name) form, resolved through the reverse map only.
    func resolve(serverHandle: String, tool: String) -> Resolution {
        if let server = servers[serverHandle] {
            if tool.hasPrefix(MCPNaming.prefix) {
                if let accepted = tools[tool] {
                    return accepted.serverHandle == serverHandle ? .tool(accepted) : .unknown
                }
            } else if let accepted = tools[MCPNaming.alias(handle: server.handle, segment: tool)] {
                return .tool(accepted)
            }
        }
        return resolveLegacy(rawName: MCPNaming.legacyRawName(serverName: serverHandle, toolName: tool))
    }

    private func resolveLegacy(rawName: String) -> Resolution {
        guard let owners = legacyReverse[rawName], !owners.isEmpty else { return .unknown }
        guard Self.legacyRawNameGraceEnabled else { return .legacyRefused }
        if owners.count == 1, let tool = tools[owners[0]] { return .tool(tool) }
        return .ambiguous(owners.sorted())
    }

    /// Unique legacy raw name → alias map (ambiguous names excluded), for
    /// routing-pattern canonicalization.
    var uniqueLegacyAliases: [String: String] {
        var out: [String: String] = [:]
        for (raw, owners) in legacyReverse where owners.count == 1 {
            out[raw] = owners[0]
        }
        return out
    }

    /// Escaped, handle-only auto description: up to 5 tool segments, then
    /// "and N more". Never shows raw tool names.
    func autoDescription(handle: String) -> String {
        guard let server = servers[handle] else { return "" }
        let segments = server.aliases.compactMap { MCPNaming.splitAlias($0)?.segment }.sorted()
        if segments.count <= 5 {
            return "Provides: \(segments.joined(separator: ", "))"
        }
        return "Provides: \(segments.prefix(5).joined(separator: ", ")), and \(segments.count - 5) more"
    }

    /// Description shown in the deferred-server prompt section: the user's
    /// configured text if any, else the auto description; escaped either way.
    func promptDescription(handle: String) -> String {
        guard let server = servers[handle] else { return "" }
        if let configured = server.configuredDescription, !configured.isEmpty {
            return MarkerNeutralizer.escape(configured)
        }
        return MarkerNeutralizer.escape(autoDescription(handle: handle))
    }

    /// `tool_search` result: every accepted tool of one server, rendered from
    /// the validated definitions (aliases, escaped descriptions, validated
    /// keys/types/enums). Nil when the handle is unknown or has no tools.
    func schemaListing(handle: String) -> String? {
        guard let server = servers[handle], !server.aliases.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("MCP server '\(handle)' — \(server.aliases.count) tools:")
        lines.append("")
        for alias in server.aliases.sorted() {
            guard let tool = tools[alias] else { continue }
            let def = tool.definition.function
            lines.append("## \(alias)")
            // The definition description already carries the escaped text
            // plus the "(Provided by …)" suffix; show the escaped body only.
            let body = MarkerNeutralizer.escape(tool.description)
            if !body.isEmpty { lines.append(body) }
            let props = def.parameters.properties
            let required = Set(def.parameters.required)
            if props.isEmpty {
                lines.append("Parameters: none")
            } else {
                lines.append("Parameters:")
                for key in props.keys.sorted() {
                    guard let p = props[key] else { continue }
                    let req = required.contains(key) ? " (required)" : ""
                    let enumNote = (p.enumValues?.isEmpty == false)
                        ? " — enum: \(p.enumValues!.joined(separator: ", "))" : ""
                    let desc = p.description.isEmpty ? "" : " — \(p.description)"
                    lines.append("  - \(key): \(p.type)\(req)\(enumNote)\(desc)")
                }
            }
            lines.append("")
        }
        lines.append("Use mcp_call(server: \"\(handle)\", tool: \"<tool alias exactly as listed>\", arguments: {...}) to invoke.")
        return lines.joined(separator: "\n")
    }
}
