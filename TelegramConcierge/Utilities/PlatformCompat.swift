import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Cross-platform shims
//
// Briglia CLI builds on macOS and Linux. Everything genuinely platform-specific
// funnels through this file so the rest of the codebase stays identical to
// Ada.app (which keeps upstream merges clean).

#if !canImport(Darwin)
/// The codebase calls `Darwin.kill(pid, sig)` in the process-tree teardown
/// paths. On Linux the same POSIX call lives in Glibc; this shim keeps the
/// call sites untouched.
enum Darwin {
    @discardableResult
    static func kill(_ pid: Int32, _ sig: Int32) -> Int32 {
        Glibc.kill(pid, sig)
    }
}
#endif

/// Platform facts the services need at runtime.
enum PlatformShell {
    /// The login shell the `bash` tool family runs commands through.
    /// macOS ships zsh as the default shell; Linux distributions ship bash.
    #if os(macOS)
    static let path = "/bin/zsh"
    #else
    static let path = "/bin/bash"
    #endif

    /// Human-readable form used inside tool descriptions shown to the model.
    static var displayName: String { path + " -lc" }

    /// Bare shell name ("zsh"/"bash") for tool descriptions that ask the
    /// model to WRITE scripts — they must target the shell that will
    /// actually execute them on this platform.
    static var name: String { (path as NSString).lastPathComponent }
}

/// Operating-system identity for model-facing text and outbound User-Agent
/// strings. The system prompt must never claim the wrong OS — the model
/// derives paths, package managers, and service commands from it.
enum PlatformOS {
    #if os(macOS)
    static let promptName = "Mac"
    static let userAgentToken = "macOS"
    #else
    static let promptName = "Linux"
    static let userAgentToken = "Linux"
    #endif
}

/// Locate an executable by searching $PATH plus the usual install prefixes.
/// Foundation offers no cross-platform `which`; this is deliberately simple.
enum PlatformBinary {
    static func find(_ name: String) -> String? {
        var candidates: [String] = []
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            candidates += pathVar.split(separator: ":").map { "\($0)/\(name)" }
        }
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run a binary synchronously, capturing stdout. Returns nil on launch
    /// failure or non-zero exit. Used by the Linux media pipeline, where the
    /// inputs are small local files and the tools (poppler, ImageMagick)
    /// finish in well under a second.
    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin data: Data? = nil, timeout: TimeInterval = 60) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        let inPipe: Pipe? = data != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }
        do { try process.run() } catch { return nil }
        if let inPipe, let data {
            inPipe.fileHandleForWriting.write(data)
            try? inPipe.fileHandleForWriting.close()
        }
        // Read fully before waiting so large outputs can't deadlock the pipe.
        let output = outPipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 ? output : nil
    }
}
