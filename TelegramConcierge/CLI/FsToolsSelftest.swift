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
        // Isolated XDG roots: section 8 exercises the harness secret store
        // through the file tools and must never touch a real installation.
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)

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

        // 8. Harness secret store through the file tools (HarnessSecretStore):
        //    the Telegram bot token is masked on read and its field is
        //    refused on edit; every other field stays editable; whole-file
        //    rewrites are refused; files elsewhere are untouched by the rules.
        let token = "5551234567:AAGoldenTokenValue_0123456789abcdef"
        let serperV1 = "serper-visible-key-abcdef0123"
        let opencodeKey = "sk-opencode-visible-0123456789"
        try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
        try KeychainHelper.save(key: KeychainHelper.serperApiKeyKey, value: serperV1)
        try KeychainHelper.save(key: ProviderProfiles.opencodeApiKeyKey, value: opencodeKey)
        let storePath = HarnessSecretStore.storePath
        check("secret store resolved under the isolated config root",
              StoragePaths.configRoot.path.hasPrefix(tempRoot.path), storePath)
        func rawStore() -> String { (try? String(contentsOfFile: storePath, encoding: .utf8)) ?? "" }
        func storedToken() -> String? {
            (try? Data(contentsOf: URL(fileURLWithPath: storePath)))
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?[KeychainHelper.telegramBotTokenKey]
        }
        func succeeded(_ r: FilesystemTools.OpResult) -> Bool {
            ((try? JSONSerialization.jsonObject(with: Data(r.content.utf8))) as? [String: Any])?["success"] as? Bool == true
        }
        let storeRead = await FilesystemTools.shared.readFile(path: storePath)
        check("read_file masks the Telegram bot token",
              storeRead.content.contains(HarnessSecretStore.tokenPlaceholder) && !storeRead.content.contains(token),
              String(storeRead.content.prefix(300)))
        check("read_file returns the other keys verbatim",
              storeRead.content.contains(serperV1) && storeRead.content.contains(opencodeKey))
        let serperV2 = "serper-visible-key-ghijkl4567"
        let editSerper = await FilesystemTools.shared.editFile(path: storePath, oldString: serperV1, newString: serperV2)
        check("edit_file of the Serper key succeeds", succeeded(editSerper), String(editSerper.content.prefix(300)))
        check("...and the stored token is byte-identical afterwards",
              storedToken() == token && rawStore().contains(serperV2))
        let editPlaceholder = await FilesystemTools.shared.editFile(
            path: storePath, oldString: serperV2, newString: HarnessSecretStore.tokenPlaceholder)
        check("edit_file writing a [REDACTED:…] placeholder back is refused",
              !succeeded(editPlaceholder) && editPlaceholder.content.contains("placeholder"),
              String(editPlaceholder.content.prefix(300)))
        let editTokenField = await FilesystemTools.shared.editFile(
            path: storePath, oldString: "\"\(KeychainHelper.telegramBotTokenKey)\"", newString: "\"telegram_bot_token_old\"")
        check("edit_file touching the token field is refused",
              !succeeded(editTokenField) && editTokenField.content.contains("/switchbot"),
              String(editTokenField.content.prefix(300)))
        let editTokenValue = await FilesystemTools.shared.editFile(path: storePath, oldString: token, newString: "x")
        check("edit_file touching the token value is refused", !succeeded(editTokenValue))
        let writeStore = await FilesystemTools.shared.writeFile(path: storePath, content: "{}\n")
        check("write_file on the secret store is refused",
              !succeeded(writeStore) && writeStore.content.contains("whole-file"),
              String(writeStore.content.prefix(300)))
        check("...and the store is unchanged", storedToken() == token && rawStore().contains(serperV2))
        // apply_patch: a hunk on the Serper line applies; hunks on the token
        // field, deletes and moves are refused.
        let serperLine = rawStore().components(separatedBy: "\n").first { $0.contains(serperV2) } ?? ""
        let serperV3 = "serper-visible-key-mnopqr8901"
        let patchSerper = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(storePath)
        @@
        -\(serperLine)
        +\(serperLine.replacingOccurrences(of: serperV2, with: serperV3))
        *** End Patch
        """)
        check("apply_patch of the Serper key succeeds",
              !patchSerper.content.contains("\"error\"") && rawStore().contains(serperV3),
              String(patchSerper.content.prefix(300)))
        check("...and the stored token is byte-identical after the patch", storedToken() == token)
        let tokenLine = rawStore().components(separatedBy: "\n").first { $0.contains("\"\(KeychainHelper.telegramBotTokenKey)\"") } ?? ""
        let patchToken = await ApplyPatch.run(patchText: """
        *** Begin Patch
        *** Update File: \(storePath)
        @@
        -\(tokenLine)
        +\(tokenLine.replacingOccurrences(of: token, with: "1:new"))
        *** End Patch
        """)
        check("apply_patch touching the token field is refused",
              patchToken.content.contains("\"error\"") && patchToken.content.contains("/switchbot") && storedToken() == token,
              String(patchToken.content.prefix(300)))
        let patchDelete = await ApplyPatch.run(patchText: "*** Begin Patch\n*** Delete File: \(storePath)\n*** End Patch")
        check("apply_patch deleting the secret store is refused",
              patchDelete.content.contains("\"error\"") && FileManager.default.fileExists(atPath: storePath),
              String(patchDelete.content.prefix(300)))
        // The rules are scoped to the harness store: a user .env elsewhere is untouched.
        let envPath = tempRoot.appendingPathComponent("project.env").path
        let envWrite = await FilesystemTools.shared.writeFile(
            path: envPath, content: "TOKEN=\(HarnessSecretStore.tokenPlaceholder)\nBOT=\(token)\n")
        check("write_file on a user .env with the same strings is allowed", succeeded(envWrite),
              String(envWrite.content.prefix(300)))
        let envRead = await FilesystemTools.shared.readFile(path: envPath)
        check("read_file on a user .env is not masked", envRead.content.contains(token))
        let envEdit = await FilesystemTools.shared.editFile(path: envPath, oldString: "BOT=\(token)", newString: "BOT=other")
        check("edit_file on a user .env touching the token string is allowed", succeeded(envEdit),
              String(envEdit.content.prefix(300)))

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
