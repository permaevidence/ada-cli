import Foundation

/// Canonical on-disk locations for Briglia CLI.
///
/// The CLI deliberately does NOT use Ada.app's paths (`~/Library/Application
/// Support/Ada` and `~/Ada`) so both products can coexist on the same Mac.
/// XDG-style paths are used on macOS too, which makes them valid unchanged on
/// Linux.
///
/// Roots are RESOLVED lazily but never CREATED by resolution (rename plan
/// §4.2): a diagnostic command (`--version`, `bundle-check`, `doctor`,
/// `setup-api status`, `service status`, `migrate --status`) must not
/// materialize empty `~/.config/briglia` / `~/.local/share/briglia`
/// directories — an empty new root would mask the "old install present,
/// new roots absent" detection that gates the explicit `briglia migrate`.
/// Mutating entry points call `ensureRoots()` first; the secret store
/// creates its own parent on write.
enum StoragePaths {
    /// The product directory name under the XDG bases.
    static let productDirName = "briglia"

    /// State and caches (sessions, archives, ledger, logs, attachments,
    /// projects): `$XDG_DATA_HOME/briglia`, default `~/.local/share/briglia`.
    static let dataRoot: URL = resolveDataRoot()

    /// User-editable configuration (mcp.json, mcp-routing.json, agents/,
    /// skills/, agent-turns.json): `$XDG_CONFIG_HOME/briglia`, default
    /// `~/.config/briglia`.
    static let configRoot: URL = resolveConfigRoot()

    /// Human-readable equivalents for prompts and user-facing messages.
    static let dataRootDisplay = "~/.local/share/briglia"
    static let configRootDisplay = "~/.config/briglia"

    /// Pure resolution (no filesystem effects), also used by the identity
    /// migration to compute the OLD product's roots under the same XDG rules.
    static func resolveDataRoot(productDirName name: String = productDirName,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        xdgBase(env: "XDG_DATA_HOME", fallback: ".local/share",
                environment: environment, home: home)
            .appendingPathComponent(name, isDirectory: true)
    }

    static func resolveConfigRoot(productDirName name: String = productDirName,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        xdgBase(env: "XDG_CONFIG_HOME", fallback: ".config",
                environment: environment, home: home)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// Create both roots (idempotent). Called by every entry point that is
    /// allowed to write state; never by diagnostics.
    static func ensureRoots() {
        for root in [configRoot, dataRoot] {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    private static func xdgBase(env: String, fallback: String,
                                environment: [String: String], home: URL) -> URL {
        if let value = environment[env], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return home.appendingPathComponent(fallback, isDirectory: true)
    }
}
