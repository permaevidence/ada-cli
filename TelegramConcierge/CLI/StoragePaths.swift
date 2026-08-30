import Foundation

/// Canonical on-disk locations for Ada CLI.
///
/// The CLI deliberately does NOT use Ada.app's paths (`~/Library/Application
/// Support/Ada` and `~/Ada`) so both products can coexist on the same Mac.
/// XDG-style paths are used on macOS too, which makes them valid unchanged on
/// Linux in Phase 2.
enum StoragePaths {
    /// State and caches (sessions, archives, ledger, logs, attachments,
    /// projects): `$XDG_DATA_HOME/ada`, default `~/.local/share/ada`.
    static let dataRoot: URL = {
        let root = xdgBase(env: "XDG_DATA_HOME", fallback: ".local/share")
            .appendingPathComponent("ada", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// User-editable configuration (mcp.json, mcp-routing.json, agents/,
    /// skills/, agent-turns.json): `$XDG_CONFIG_HOME/ada`, default
    /// `~/.config/ada`.
    static let configRoot: URL = {
        let root = xdgBase(env: "XDG_CONFIG_HOME", fallback: ".config")
            .appendingPathComponent("ada", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// Human-readable equivalents for prompts and user-facing messages.
    static let dataRootDisplay = "~/.local/share/ada"
    static let configRootDisplay = "~/.config/ada"

    private static func xdgBase(env: String, fallback: String) -> URL {
        if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(fallback, isDirectory: true)
    }
}
