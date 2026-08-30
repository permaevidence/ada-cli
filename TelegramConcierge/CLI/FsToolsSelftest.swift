import ArgumentParser
import Foundation

/// Hidden deterministic test of the filesystem tools' model-facing contract:
/// tool-result JSON must show file content byte-faithfully (no `\/` escaping —
/// Foundation escapes forward slashes by default, which taught models to copy
/// `\/home\/...` into old_string), the escape-mismatch hint must cover the
/// `\/` failure mode, and the read-before-edit error must explain that the
/// read ledger resets across restarts. Operates only on files inside a temp
/// directory so it never disturbs a real installation.
struct FsToolsSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__fstools-selftest",
        abstract: "Internal: verify filesystem tool JSON fidelity and edit diagnostics.",
        shouldDisplay: false
    )

    func run() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-fstools-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        // 1. read_file returns slashes unescaped in the JSON the model sees.
        let slashFile = tempRoot.appendingPathComponent("paths.txt").path
        let slashContent = "source=/home/phablet/video.qml\ndest=/usr/local/share\n"
        try slashContent.write(toFile: slashFile, atomically: true, encoding: .utf8)
        let readResult = await FilesystemTools.shared.readFile(path: slashFile)
        check("read_file result contains plain /home/phablet path",
              readResult.content.contains("/home/phablet/video.qml"))
        check("read_file result contains no escaped slashes",
              !readResult.content.contains("\\/"), String(readResult.content.prefix(200)))

        // 2. write_file / edit_file result JSON (paths, diffs) also unescaped.
        let writeResult = await FilesystemTools.shared.writeFile(
            path: tempRoot.appendingPathComponent("w.txt").path, content: "a/b/c\n")
        check("write_file result contains no escaped slashes",
              !writeResult.content.contains("\\/"), String(writeResult.content.prefix(200)))
        let editOK = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "/usr/local/share", newString: "/opt/share")
        check("edit_file success result contains no escaped slashes",
              !editOK.content.contains("\\/"), String(editOK.content.prefix(200)))

        // 3. The \/ footgun itself: old_string copied from JSON-escaped display
        //    fails the match but now gets the escape-mismatch hint.
        let editEscaped = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "source=\\/home\\/phablet\\/video.qml", newString: "x")
        check("escaped-slash old_string fails with re-read hint",
              editEscaped.content.contains("old_string not found")
              && editEscaped.content.contains("Hint")
              && editEscaped.content.contains("exact bytes"), String(editEscaped.content.prefix(300)))

        // 4. Existing hint behavior preserved: literal \n where the file has newlines.
        let editNewline = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "video.qml\\ndest=", newString: "x")
        check("escaped-newline old_string still hints",
              editNewline.content.contains("Hint") && editNewline.content.contains("exact bytes"),
              String(editNewline.content.prefix(300)))

        // 5. A genuinely absent string gets no hint (message stays clean).
        let editAbsent = await FilesystemTools.shared.editFile(
            path: slashFile, oldString: "not in the file at all", newString: "x")
        check("plain no-match carries no escape hint",
              editAbsent.content.contains("old_string not found")
              && !editAbsent.content.contains("Hint"), String(editAbsent.content.prefix(300)))

        // 6. escapeMismatchHint unit checks, including the new "/" table entry.
        check("hint unit: \\/ in old_string vs plain source",
              EditStrategies.escapeMismatchHint(source: "path /a/b end",
                                                oldString: "path \\/a\\/b end") != nil)
        check("hint unit: no false positive on matching plain strings",
              EditStrategies.escapeMismatchHint(source: "plain text", oldString: "other text") == nil)

        // 7. Read-before-edit error explains the ledger reset (restart testimony).
        let freshFile = tempRoot.appendingPathComponent("unread.txt").path
        try "hello\n".write(toFile: freshFile, atomically: true, encoding: .utf8)
        let editUnread = await FilesystemTools.shared.editFile(
            path: freshFile, oldString: "hello", newString: "ciao")
        check("edit of never-read file mentions ledger reset on restart",
              editUnread.content.contains("read_file first")
              && editUnread.content.contains("restart"), String(editUnread.content.prefix(300)))

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
