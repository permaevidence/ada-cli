import Foundation

/// Raw config entry for a single MCP server, loaded from `~/.config/briglia/mcp.json`.
///
/// The file format matches Claude Desktop's conventional shape so users can
/// copy existing configurations directly:
///
/// ```json
/// {
///   "mcpServers": {
///     "playwright": {
///       "command": "npx",
///       "args": ["@playwright/mcp@latest"],
///       "env": { "HEADED": "1" },
///       "disabled": false,
///       "secretRefs": ["GITHUB_TOKEN"]
///     }
///   }
/// }
/// ```
///
/// `secretRefs` (optional) names Keychain keys that will be resolved and merged
/// into the subprocess environment as `VAR_NAME=<keychain value>`. The
/// Keychain key itself is `mcp_env_<server>_<VAR_NAME>` (populated via Settings
/// in a later phase). This keeps plaintext secrets out of mcp.json.
public struct MCPServerConfig: Sendable, Equatable {
    public let name: String
    public let command: String
    public let arguments: [String]
    public let environment: [String: String]
    public let disabled: Bool
    public let secretRefs: [String]
    /// Human-readable purpose shown to the LLM when the server is deferred
    /// for an agent. Auto-generated from tool names if nil.
    public let description: String?

    public init(
        name: String,
        command: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        disabled: Bool = false,
        secretRefs: [String] = [],
        description: String? = nil
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.disabled = disabled
        self.secretRefs = secretRefs
        self.description = description
    }
}

/// A tool exposed by a connected MCP server, plus its server origin.
///
/// `inputSchema` is the raw JSON Schema from `tools/list`. We preserve it
/// verbatim so the conversion to our native `ToolDefinition` can do a
/// best-effort flatten without losing the original for debugging or future
/// richer serialization.
public struct MCPTool: Sendable {
    public let serverName: String
    public let toolName: String               // Original name as advertised by the server.
    public let description: String
    public let inputSchema: [String: Any]     // Raw JSON object.

    /// Legacy raw wire name (`mcp__<server>__<tool>`), as advertised before
    /// the two-level identity. The model now sees `MCPToolSurface` aliases;
    /// this form survives only as a reverse-map key during the grace release.
    public var legacyRawName: String { MCPNaming.legacyRawName(serverName: serverName, toolName: toolName) }

    public init(serverName: String, toolName: String, description: String, inputSchema: [String: Any]) {
        self.serverName = serverName
        self.toolName = toolName
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MCPClientError: Error, CustomStringConvertible {
    case notStarted
    case spawnFailed(String)
    case handshakeFailed(String)
    case responseError(String)
    case terminated
    case writeFailed(String)
    case unknownServer(String)
    case unknownTool(String)
    case timedOut(method: String, seconds: Int)

    public var description: String {
        switch self {
        case .notStarted: return "MCP client not started"
        case .spawnFailed(let msg): return "MCP spawn failed: \(msg)"
        case .handshakeFailed(let msg): return "MCP handshake failed: \(msg)"
        case .responseError(let msg): return "MCP response error: \(msg)"
        case .terminated: return "MCP server terminated"
        case .writeFailed(let msg): return "MCP write failed: \(msg)"
        case .unknownServer(let name): return "Unknown MCP server: \(name)"
        case .unknownTool(let name): return "Unknown MCP tool: \(name)"
        case .timedOut(let method, let seconds): return "MCP request '\(method)' timed out after \(seconds)s (server unresponsive)"
        }
    }
}

public enum MCPFrameError: Error, CustomStringConvertible {
    case invalidBody
    case invalidEncoding

    public var description: String {
        switch self {
        case .invalidBody: return "invalid MCP JSON body"
        case .invalidEncoding: return "invalid MCP message encoding"
        }
    }
}

/// Protocol version we advertise in `initialize`. The MCP spec tolerates older
/// versions gracefully; `2024-11-05` is the first stable release and is
/// accepted by every public server in the wild as of mid-2026.
public enum MCPProtocol {
    public static let version = "2024-11-05"
    public static let clientName = "Briglia"
    public static let clientVersion = "1.0"
}
