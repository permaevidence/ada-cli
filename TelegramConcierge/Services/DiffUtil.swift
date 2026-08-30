import Foundation

/// Unified-diff helper for write_file / edit_file / apply_patch results.
/// Shells out to /usr/bin/diff (always present on macOS) to produce a
/// standard unified-diff payload, then caps large output so huge rewrites do
/// not bloat the tool result. The diff goes into the *current turn's*
/// tool result only — it never enters the cached system-prompt prefix, so
/// there is no prompt-cache impact.
enum DiffUtil {

    /// Return a unified diff of `old` → `new`, or nil if diff is empty / the
    /// subprocess fails. The caller should treat nil as "no diff to show".
    ///
    /// - Parameters:
    ///   - old: pre-image text. Pass "" when creating a new file.
    ///   - new: post-image text.
    ///   - path: absolute path of the file — used only in the diff headers
    ///     (`--- a/<path>` / `+++ b/<path>`) so the model sees a meaningful
    ///     location instead of a tmpfile path.
    ///   - context: number of context lines around each hunk (default 3).
    ///   - maxLines: cap on total diff lines returned (default 400).
    ///   - maxBytes: cap on total diff bytes returned (default 64 KB).
    static func unifiedDiff(
        old: String,
        new: String,
        path: String,
        context: Int = 3,
        maxLines: Int = 400,
        maxBytes: Int = 64 * 1024
    ) -> String? {
        if old == new { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
        let stamp = UUID().uuidString.prefix(8)
        let oldURL = tmpDir.appendingPathComponent("ada-diff-\(stamp).old")
        let newURL = tmpDir.appendingPathComponent("ada-diff-\(stamp).new")
        defer {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.removeItem(at: newURL)
        }
        do {
            try (old.data(using: .utf8) ?? Data()).write(to: oldURL, options: .atomic)
            try (new.data(using: .utf8) ?? Data()).write(to: newURL, options: .atomic)
        } catch {
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        proc.arguments = ["-u", "-U", String(context), oldURL.path, newURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        // `diff` exits 0 when identical, 1 when different, 2 on trouble.
        guard proc.terminationStatus == 1 else { return nil }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        // Replace tmpfile paths in the two header lines with the real path.
        text = text.replacingOccurrences(of: oldURL.path, with: "a/" + path)
        text = text.replacingOccurrences(of: newURL.path, with: "b/" + path)

        return cap(text, maxLines: maxLines, maxBytes: maxBytes)
    }

    private static func cap(_ text: String, maxLines: Int, maxBytes: Int) -> String {
        var truncated = false
        var working = text
        let rawLines = working.split(separator: "\n", omittingEmptySubsequences: false)
        if rawLines.count > maxLines {
            working = rawLines.prefix(maxLines).joined(separator: "\n")
            truncated = true
        }
        if working.utf8.count > maxBytes {
            let clipped = Array(working.utf8).prefix(maxBytes)
            working = String(bytes: clipped, encoding: .utf8) ?? working
            truncated = true
        }
        if truncated {
            working += "\n… [diff truncated at \(maxLines) lines / \(maxBytes) bytes]"
        }
        return working
    }
}
