import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Hidden deterministic test of `PrivateStorage`: scope classification, the
/// atomic owner-only writer (mode policy, three-way symlink policy, refusals),
/// directory and append-handle creation, the startup sweep, and the doctor
/// report. Runs against throwaway XDG roots under a temp directory and never
/// touches a real installation.
struct StorageSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__storage-selftest",
        abstract: "Internal: verify private-by-default storage (modes, symlink policy, sweep).",
        shouldDisplay: false
    )

    func run() async throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("briglia-storage-selftest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        // A permissive umask so "new files are 0600" is the helper's doing,
        // not the environment's.
        umask(0o022)

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func mode(_ path: String) -> Int {
            var st = stat()
            guard lstat(path, &st) == 0 else { return -1 }
            return Int(st.st_mode & 0o7777)
        }
        func octal(_ m: Int) -> String { m < 0 ? "absent" : String(m, radix: 8) }
        func isLink(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
        }
        func contents(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
        }
        func plant(_ path: String, _ text: String, _ m: Int) throws {
            try fm.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: false, encoding: .utf8)
            _ = chmod(path, mode_t(m))
        }

        let configRoot = StoragePaths.configRoot
        let dataRoot = StoragePaths.dataRoot
        let external = tempRoot.appendingPathComponent("external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)

        // MARK: 1. Roots and classification
        print("\n[1] roots and scope classification")
        StoragePaths.ensureRoots()
        check("1.1 config root created 0700", mode(configRoot.path) == 0o700, octal(mode(configRoot.path)))
        check("1.2 data root created 0700", mode(dataRoot.path) == 0o700, octal(mode(dataRoot.path)))
        _ = chmod(dataRoot.path, 0o755)
        StoragePaths.ensureRoots()
        check("1.3 ensureRoots re-tightens a widened root", mode(dataRoot.path) == 0o700, octal(mode(dataRoot.path)))

        typealias S = PrivateStorage.Scope
        let cases: [(String, S)] = [
            (dataRoot.appendingPathComponent("conversation.json").path, .harnessState),
            (dataRoot.appendingPathComponent("reminders.json").path, .harnessState),
            (configRoot.appendingPathComponent("secrets.json").path, .harnessState),
            (configRoot.appendingPathComponent("mcp.json").path, .harnessState),
            (dataRoot.appendingPathComponent("archive/2026-01.json").path, .harnessState),
            (dataRoot.appendingPathComponent("subagent_sessions/abcde.json").path, .harnessState),
            (dataRoot.appendingPathComponent("logs/web-pipeline.log").path, .harnessState),
            (dataRoot.appendingPathComponent("reminder-scripts/state/x.json").path, .harnessState),
            (dataRoot.appendingPathComponent("reminder-scripts/daily.sh").path, .inScope),
            (dataRoot.appendingPathComponent("documents/a.pdf").path, .inScope),
            (configRoot.appendingPathComponent("skills/pdf/helper.sh").path, .inScope),
            (configRoot.appendingPathComponent("agents/x.md").path, .inScope),
            (dataRoot.appendingPathComponent("projects/p/main.py").path, .outside),
            (dataRoot.appendingPathComponent("toolchain/bin/pdftotext").path, .outside),
            (external.appendingPathComponent("x").path, .outside),
            (dataRoot.path, .harnessState),
        ]
        for (path, expected) in cases {
            let got = PrivateStorage.classify(path)
            check("1.4 classify \(path.replacingOccurrences(of: tempRoot.path, with: "…")) → \(expected)", got == expected, "got \(got)")
        }
        // Classification of a path not yet on disk under a root reached via a symlinked prefix.
        let aliasRoot = tempRoot.appendingPathComponent("alias")
        symlink(tempRoot.appendingPathComponent("data").path, aliasRoot.path)
        check("1.5 classify through a symlinked root prefix",
              PrivateStorage.classify(aliasRoot.appendingPathComponent("briglia/todos.json").path) == .harnessState)
        check("1.6 isUnderRoots covers excluded areas too",
              PrivateStorage.isUnderRoots(dataRoot.appendingPathComponent("projects/x").path)
              && !PrivateStorage.isUnderRoots(external.path))

        // MARK: 2. Atomic writer mode policy
        print("\n[2] atomic writer")
        let fresh = dataRoot.appendingPathComponent("fresh.json")
        try PrivateStorage.writeAtomically(Data("{}".utf8), to: fresh)
        check("2.1 new file is 0600 under umask 022", mode(fresh.path) == 0o600, octal(mode(fresh.path)))
        check("2.2 new file content", contents(fresh.path) == "{}")
        let wide = dataRoot.appendingPathComponent("wide.json")
        try plant(wide.path, "old", 0o644)
        try PrivateStorage.writeAtomically(Data("new".utf8), to: wide)
        check("2.3 existing 0644 becomes 0600 on rewrite", mode(wide.path) == 0o600, octal(mode(wide.path)))
        check("2.4 rewrite replaced the content", contents(wide.path) == "new")
        let helper = configRoot.appendingPathComponent("skills/demo/helper.sh")
        try plant(helper.path, "#!/bin/sh\necho old\n", 0o755)
        try PrivateStorage.writeAtomically(Data("#!/bin/sh\necho new\n".utf8), to: helper)
        check("2.5 existing 0755 helper keeps owner exec, loses group/other (0700)", mode(helper.path) == 0o700, octal(mode(helper.path)))
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = [helper.path]
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        run.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check("2.6 rewritten helper still executes", run.terminationStatus == 0 && out == "new\n", out)
        let private700 = dataRoot.appendingPathComponent("reminder-scripts/keep.sh")
        try plant(private700.path, "a", 0o700)
        try PrivateStorage.writeAtomically(Data("b".utf8), to: private700)
        check("2.7 existing 0700 stays 0700", mode(private700.path) == 0o700, octal(mode(private700.path)))
        let explicit = dataRoot.appendingPathComponent("reminder-scripts/new.sh")
        try PrivateStorage.writeAtomically(Data("x".utf8), to: explicit, mode: 0o700)
        check("2.8 explicit mode applied to a new file", mode(explicit.path) == 0o700, octal(mode(explicit.path)))
        let leftovers = (try? fm.contentsOfDirectory(atPath: dataRoot.path))?.filter { $0.hasPrefix(".") && $0.contains(".tmp-") } ?? []
        check("2.9 no staging temp left behind", leftovers.isEmpty, leftovers.joined(separator: ","))
        let dirTarget = dataRoot.appendingPathComponent("documents")
        try fm.createDirectory(at: dirTarget, withIntermediateDirectories: true)
        var refused = false
        do { try PrivateStorage.writeAtomically(Data(), to: dirTarget) } catch { refused = true }
        check("2.10 writing over a directory is refused", refused && fm.fileExists(atPath: dirTarget.path))
        let fifo = dataRoot.appendingPathComponent("pipe")
        if mkfifo(fifo.path, 0o600) == 0 {
            refused = false
            do { try PrivateStorage.writeAtomically(Data(), to: fifo) } catch { refused = true }
            check("2.11 writing over a FIFO is refused", refused)
            unlink(fifo.path)
        }

        // MARK: 3. Symlink policy
        print("\n[3] symlink policy")
        // (i) link at a user path resolving to harness state → refused, state untouched.
        let conv = dataRoot.appendingPathComponent("conversation.json")
        try plant(conv.path, "HISTORY", 0o600)
        let evil = configRoot.appendingPathComponent("skills/evil")
        symlink(conv.path, evil.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("pwn".utf8), to: evil) } catch { refused = true }
        check("3.1 link resolving to harness state is refused", refused)
        check("3.2 harness state untouched after the refusal", contents(conv.path) == "HISTORY" && !isLink(conv.path))
        // (i') link placed AT a harness state path → refused regardless of target.
        let extPlain = external.appendingPathComponent("plain.json")
        try plant(extPlain.path, "ext", 0o644)
        let rem = dataRoot.appendingPathComponent("reminders.json")
        symlink(extPlain.path, rem.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: rem) } catch { refused = true }
        check("3.3 a symlink at a harness-state path is refused", refused)
        check("3.4 its external target is untouched", contents(extPlain.path) == "ext" && mode(extPlain.path) == 0o644)
        unlink(rem.path)
        // (ii) in-scope link: helper → another in-root file, 0755.
        let shared = dataRoot.appendingPathComponent("documents/shared.sh")
        try plant(shared.path, "old", 0o755)
        let link2 = configRoot.appendingPathComponent("skills/demo/link.sh")
        symlink(shared.path, link2.path)
        let written = try PrivateStorage.writeAtomically(Data("new".utf8), to: link2)
        check("3.5 in-scope link written through (target updated)", contents(shared.path) == "new" && written == PrivateStorage.canonical(shared.path))
        check("3.6 the link is still a link", isLink(link2.path))
        check("3.7 in-scope target stripped to 0700", mode(shared.path) == 0o700, octal(mode(shared.path)))
        // (iii) external target keeps its exact mode.
        let extScript = external.appendingPathComponent("script.sh")
        try plant(extScript.path, "old", 0o755)
        let link3 = configRoot.appendingPathComponent("skills/demo/ext.sh")
        symlink(extScript.path, link3.path)
        try PrivateStorage.writeAtomically(Data("new".utf8), to: link3)
        check("3.8 external target content updated through the link", contents(extScript.path) == "new")
        check("3.9 external target mode preserved exactly (0755)", mode(extScript.path) == 0o755, octal(mode(extScript.path)))
        check("3.10 external link still a link", isLink(link3.path))
        let proj = dataRoot.appendingPathComponent("projects/p/build.sh")
        try plant(proj.path, "old", 0o755)
        let link4 = configRoot.appendingPathComponent("skills/demo/proj.sh")
        symlink(proj.path, link4.path)
        try PrivateStorage.writeAtomically(Data("new".utf8), to: link4)
        check("3.11 projects/ target keeps 0755 through the link", contents(proj.path) == "new" && mode(proj.path) == 0o755, octal(mode(proj.path)))
        // dangling and cycle
        let dangling = configRoot.appendingPathComponent("skills/demo/dangling")
        symlink(external.appendingPathComponent("missing").path, dangling.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: dangling) } catch { refused = true }
        check("3.12 dangling link refused", refused)
        check("3.13 dangling target not created", !fm.fileExists(atPath: external.appendingPathComponent("missing").path))
        let cycA = configRoot.appendingPathComponent("skills/demo/cycA")
        let cycB = configRoot.appendingPathComponent("skills/demo/cycB")
        symlink(cycB.path, cycA.path)
        symlink(cycA.path, cycB.path)
        refused = false
        var cycleMessage = ""
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: cycA) } catch { refused = true; cycleMessage = "\(error)" }
        check("3.14 symlink cycle refused", refused && cycleMessage.contains("cycle"), cycleMessage)
        let linkToDir = configRoot.appendingPathComponent("skills/demo/todir")
        symlink(dirTarget.path, linkToDir.path)
        refused = false
        do { try PrivateStorage.writeAtomically(Data("x".utf8), to: linkToDir) } catch { refused = true }
        check("3.15 link to a directory refused", refused)

        // MARK: 4. Directories and append handles
        print("\n[4] directories and append handles")
        let nested = dataRoot.appendingPathComponent("reminder-scripts/state/deep")
        try PrivateStorage.ensureDirectory(nested)
        check("4.1 nested directories created 0700 under umask 022",
              mode(nested.path) == 0o700 && mode(nested.deletingLastPathComponent().path) == 0o700,
              "\(octal(mode(nested.path))) / \(octal(mode(nested.deletingLastPathComponent().path)))")
        let wideDir = dataRoot.appendingPathComponent("images")
        try fm.createDirectory(at: wideDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try PrivateStorage.ensureDirectory(wideDir)
        check("4.2 existing 0755 directory tightened to 0700", mode(wideDir.path) == 0o700, octal(mode(wideDir.path)))
        try PrivateStorage.ensureDirectory(wideDir)
        check("4.3 ensureDirectory is idempotent", mode(wideDir.path) == 0o700)
        refused = false
        do { try PrivateStorage.ensureDirectory(fresh) } catch { refused = true }
        check("4.4 a regular file in the way is an error", refused)
        let log = dataRoot.appendingPathComponent("logs/web-pipeline.log")
        try PrivateStorage.ensureDirectory(log.deletingLastPathComponent())
        do {
            let h = try PrivateStorage.openForAppend(log)
            try h.write(contentsOf: Data("a\n".utf8))
            try h.close()
        }
        check("4.5 append handle creates the file 0600", mode(log.path) == 0o600, octal(mode(log.path)))
        _ = chmod(log.path, 0o644)
        do {
            let h = try PrivateStorage.openForAppend(log)
            try h.write(contentsOf: Data("b\n".utf8))
            try h.close()
        }
        check("4.6 append handle tightens a 0644 log and appends", mode(log.path) == 0o600 && contents(log.path) == "a\nb\n")
        let logLink = dataRoot.appendingPathComponent("logs/other.log")
        symlink(extPlain.path, logLink.path)
        let extBefore = contents(extPlain.path)
        refused = false
        do { _ = try PrivateStorage.openForAppend(logLink) } catch { refused = true }
        check("4.7 append through a symlink refused", refused && contents(extPlain.path) == extBefore)

        // MARK: 5. Sweep
        print("\n[5] startup sweep")
        // Plant the plan's fixture: 0644 file, 0755 directory, 0755 script,
        // symlink to an external file, wide entries in the excluded areas.
        let sweepFile = dataRoot.appendingPathComponent("todos.json")
        try plant(sweepFile.path, "[]", 0o644)
        let sweepDir = dataRoot.appendingPathComponent("subagent_sessions")
        try fm.createDirectory(at: sweepDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try plant(sweepDir.appendingPathComponent("abcde.json").path, "{}", 0o664)
        let sweepScript = configRoot.appendingPathComponent("skills/demo/run.sh")
        try plant(sweepScript.path, "#!/bin/sh\necho ok\n", 0o755)
        let extForLink = external.appendingPathComponent("linked.txt")
        try plant(extForLink.path, "x", 0o644)
        let sweepLink = dataRoot.appendingPathComponent("documents/linked.txt")
        symlink(extForLink.path, sweepLink.path)
        let projWide = dataRoot.appendingPathComponent("projects/p/readme.md")
        try plant(projWide.path, "x", 0o644)
        let toolWide = dataRoot.appendingPathComponent("toolchain/bin/tool")
        try plant(toolWide.path, "x", 0o755)
        _ = chmod(dataRoot.appendingPathComponent("projects").path, 0o755)
        _ = chmod(configRoot.path, 0o755)

        let dry = PrivateStorage.sweep(apply: false)
        check("5.1 dry run counts wide entries without changing them",
              dry.tightened >= 5 && mode(sweepFile.path) == 0o644, "tightened=\(dry.tightened)")
        let report = PrivateStorage.sweep()
        check("5.2 sweep reports the same count it then fixes", report.tightened == dry.tightened, "\(report.tightened) vs \(dry.tightened)")
        check("5.3 0644 file → 0600", mode(sweepFile.path) == 0o600, octal(mode(sweepFile.path)))
        check("5.4 0755 directory → 0700", mode(sweepDir.path) == 0o700, octal(mode(sweepDir.path)))
        check("5.5 0664 file inside → 0600", mode(sweepDir.appendingPathComponent("abcde.json").path) == 0o600)
        check("5.6 0755 script → 0700, still executable by owner", mode(sweepScript.path) == 0o700, octal(mode(sweepScript.path)))
        check("5.7 widened config root → 0700", mode(configRoot.path) == 0o700, octal(mode(configRoot.path)))
        check("5.8 symlink skipped, external target untouched (0644)",
              isLink(sweepLink.path) && mode(extForLink.path) == 0o644 && report.skipped >= 1, "skipped=\(report.skipped)")
        check("5.9 projects/ content untouched (0644)", mode(projWide.path) == 0o644, octal(mode(projWide.path)))
        check("5.10 projects/ directory itself untouched (0755)", mode(dataRoot.appendingPathComponent("projects").path) == 0o755)
        check("5.11 toolchain/ content untouched (0755)", mode(toolWide.path) == 0o755, octal(mode(toolWide.path)))
        check("5.12 external target's mode preserved through the earlier write-through (0755)", mode(extScript.path) == 0o755)
        let again = PrivateStorage.sweep()
        check("5.13 second sweep is a no-op", again.tightened == 0 && again.errors.isEmpty, "tightened=\(again.tightened) errors=\(again.errors)")
        let doctor = PrivateStorage.sweep(apply: false)
        check("5.14 doctor view reports zero wide entries after the sweep", doctor.tightened == 0)
        // Budget: a tiny budget truncates instead of stalling.
        let bounded = PrivateStorage.sweep(apply: false, budget: 3)
        check("5.15 entry budget truncates the scan", bounded.truncated && bounded.scanned <= 4, "scanned=\(bounded.scanned)")
        // Execution after sweep: the 0700 script still runs.
        let run2 = Process()
        run2.executableURL = URL(fileURLWithPath: "/bin/sh")
        run2.arguments = ["-c", "\"\(sweepScript.path)\""]
        let pipe2 = Pipe()
        run2.standardOutput = pipe2
        try run2.run()
        run2.waitUntilExit()
        let out2 = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check("5.16 swept skill helper executes directly (exec bit kept)", run2.terminationStatus == 0 && out2 == "ok\n", out2)

        // MARK: 6. Writer-level checks (routing work adds them here)
        print("\n[6] state writers")
        await StorageWritersSelftest.run(tempRoot: tempRoot, check: check)

        print(failures == 0 ? "\nStorage selftest: all checks passed." : "\nStorage selftest: \(failures) check(s) FAILED.")
        if failures > 0 { throw ExitCode(1) }
    }
}
