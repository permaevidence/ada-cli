import Foundation

/// Per-language configuration: which server to spawn, how to identify
/// documents to the server, and how to find the workspace root from a
/// file path. Extension lookup returns the first matching entry.
struct LSPServerConfig {
    /// Server identity — clients are keyed by (serverID, workspaceRoot) so
    /// typescript-language-server is shared between `.ts` and `.js` files
    /// in the same project.
    let serverID: String

    /// Executable name (resolved against /opt/homebrew/bin, /usr/local/bin,
    /// /usr/bin, /bin, then `which`).
    let executable: String
    let arguments: [String]

    /// Workspace root markers. If any entry's name matches exactly OR any
    /// filename in the directory ends with the marker (for `.xcodeproj` /
    /// `.xcworkspace` etc.), that directory is the root. Walked upward from
    /// the file's parent; falls back to the parent dir if no marker found.
    let workspaceMarkers: [String]

    /// Maximum seconds to wait for publishDiagnostics after a write. Cold
    /// sourcekit-lsp and rust-analyzer need longer because they index on
    /// first touch; pylsp and tsserver are generally fast. A clean file
    /// may wait the full timeout if the server doesn't publish empty
    /// diagnostics — keep this conservative but not outrageous.
    let diagnosticsTimeout: TimeInterval
}

enum LSPLanguages {

    static let serverByID: [String: LSPServerConfig] = [
        "sourcekit-lsp": LSPServerConfig(
            serverID: "sourcekit-lsp",
            executable: "sourcekit-lsp",
            arguments: [],
            workspaceMarkers: ["Package.swift", ".xcodeproj", ".xcworkspace"],
            diagnosticsTimeout: 8.0
        ),
        "typescript-language-server": LSPServerConfig(
            serverID: "typescript-language-server",
            executable: "typescript-language-server",
            arguments: ["--stdio"],
            workspaceMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
            diagnosticsTimeout: 3.0
        ),
        "pylsp": LSPServerConfig(
            serverID: "pylsp",
            executable: "pylsp",
            arguments: [],
            workspaceMarkers: ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
            diagnosticsTimeout: 2.0
        ),
        "gopls": LSPServerConfig(
            serverID: "gopls",
            executable: "gopls",
            arguments: [],
            workspaceMarkers: ["go.mod"],
            diagnosticsTimeout: 5.0
        ),
        "rust-analyzer": LSPServerConfig(
            serverID: "rust-analyzer",
            executable: "rust-analyzer",
            arguments: [],
            workspaceMarkers: ["Cargo.toml"],
            diagnosticsTimeout: 8.0
        ),
        "vscode-json-languageserver": LSPServerConfig(
            serverID: "vscode-json-languageserver",
            executable: "vscode-json-languageserver",
            arguments: ["--stdio"],
            workspaceMarkers: [],
            diagnosticsTimeout: 1.5
        )
    ]

    /// PATH augmentation for LSP subprocesses. macOS apps launched outside
    /// a shell inherit a minimal PATH like "/usr/bin:/bin:/usr/sbin:/sbin"
    /// — that breaks servers like typescript-language-server (needs node),
    /// pylsp (needs python3), gopls (needs go), rust-analyzer (needs
    /// cargo/rustc) because their shebangs or runtimes aren't found.
    /// Prepend the common Homebrew and user-install locations.
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extras = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(extras):\(existing)"
        } else {
            env["PATH"] = extras
        }
        return env
    }

    /// Per-extension server assignment.
    static let extensionToServerID: [String: String] = [
        "swift": "sourcekit-lsp",
        "ts": "typescript-language-server",
        "tsx": "typescript-language-server",
        "js": "typescript-language-server",
        "jsx": "typescript-language-server",
        "mjs": "typescript-language-server",
        "cjs": "typescript-language-server",
        "py": "pylsp",
        "go": "gopls",
        "rs": "rust-analyzer",
        "json": "vscode-json-languageserver"
    ]

    /// LSP `languageId` text — distinct from serverID. typescript-language-server
    /// needs "typescript" vs "javascript" vs "typescriptreact" vs "javascriptreact"
    /// to pick the right analyzer internally.
    static func languageId(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "swift": return "swift"
        case "ts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py": return "python"
        case "go": return "go"
        case "rs": return "rust"
        case "json": return "json"
        default: return nil
        }
    }

    /// Lookup the server config for a given file extension (no leading dot).
    static func serverConfig(forExtension ext: String) -> LSPServerConfig? {
        guard let id = extensionToServerID[ext.lowercased()] else { return nil }
        return serverByID[id]
    }

    // MARK: - Workspace root

    /// Walk upward from the file's parent directory looking for any of the
    /// markers. Stop at root. Returns the file's own directory if nothing
    /// matches.
    static func workspaceRoot(forFilePath filePath: String, markers: [String]) -> URL {
        let fm = FileManager.default
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        var dir = fileURL.deletingLastPathComponent()
        let fallback = dir
        // Sanity cap on traversal depth.
        for _ in 0..<64 {
            if directoryContainsMarker(dir: dir, markers: markers, fm: fm) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return fallback
    }

    private static func directoryContainsMarker(dir: URL, markers: [String], fm: FileManager) -> Bool {
        guard !markers.isEmpty else { return false }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let entrySet = Set(entries)
        for m in markers {
            if m.hasPrefix(".") {
                // Extension-style marker: match any entry ending with it
                // (e.g. ".xcodeproj" → "MyApp.xcodeproj"). If an entry is
                // literally named ".xcodeproj", the exact match below covers
                // it too.
                if entrySet.contains(m) { return true }
                for e in entries where e.hasSuffix(m) { return true }
            } else {
                if entrySet.contains(m) { return true }
            }
        }
        return false
    }

    // MARK: - Executable resolution

    /// Search /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin, then `which`.
    /// Mirrors DiscoveryTools.locateExecutable so user's existing PATH-style
    /// expectations are consistent across tools.
    static func locateExecutable(_ name: String) -> String? {
        let candidatePaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in candidatePaths {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Fallback: ask the shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
