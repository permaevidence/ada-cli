import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - §8.2 AgentMail installer battery

extension SelftestContext {
    struct Fixture {
        let archive: URL
        let sums: URL
        let version: String
        let binarySHA: String
    }

    /// A fake `agentmail` binary: a shell script that prints its version,
    /// and — through the wrapper (AGENTMAIL_API_KEY exported) — fails when
    /// `failWrapped` is set, so a "published wrapper smoke test fails" can be
    /// produced deterministically.
    func makeFixture(version: String, failWrapped: Bool = false, failDirect: Bool = false) throws -> Fixture {
        let dir = tempDir("fixture-\(version)")
        let bin = dir.appendingPathComponent("agentmail")
        var script = "#!/bin/sh\n"
        if failDirect { script += "exit 1\n" }
        if failWrapped { script += "if [ \"${AGENTMAIL_API_KEY+set}\" = set ]; then exit 1; fi\n" }
        script += "echo agentmail \(version)\n"
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        let asset = "agentmail_\(version)_test.tar.gz"
        let archive = dir.appendingPathComponent(asset)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", dir.path, "agentmail"]
        try tar.run(); tar.waitUntilExit()
        let data = try Data(contentsOf: archive)
        let sums = dir.appendingPathComponent("checksums.txt")
        try "\(AgentMailService.sha256Hex(data))  \(asset)\n".write(to: sums, atomically: true, encoding: .utf8)
        return Fixture(archive: archive, sums: sums, version: version, binarySHA: AgentMailService.sha256Hex(try Data(contentsOf: bin)))
    }

    func useFixture(_ f: Fixture, slow: AsyncGate? = nil) {
        AgentMailService.downloadOverride = { _ in
            if let slow { await slow.wait() }
            return (f.version, f.archive.lastPathComponent, try Data(contentsOf: f.archive), try Data(contentsOf: f.sums))
        }
    }

    func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { ($0.hasPrefix("agentmail") || $0.hasPrefix(".agentmail")) && $0 != ".agentmail.lock" }.sorted()
    }

    func wrapperAnswers(_ dir: URL, _ version: String) -> Bool {
        let r = GoogleWorkspaceService.runBlockingProcess(executable: dir.appendingPathComponent("agentmail").path, args: ["--version"], timeoutSeconds: 10)
        return (r.stdout ?? "").contains("agentmail \(version)")
    }

    func dirHash(_ dir: URL) -> String {
        var parts: [String] = []
        for e in entries(dir) {
            let p = dir.appendingPathComponent(e)
            var st = stat()
            lstat(p.path, &st)
            let data = (try? Data(contentsOf: p)) ?? Data()
            parts.append("\(e):\(st.st_mode):\(AgentMailService.sha256Hex(data))")
        }
        return parts.joined(separator: "|")
    }

    func agentMailInstaller() async throws {
        AgentMailService.brigliaPathOverride = "/usr/bin/true"
        defer { AgentMailService.brigliaPathOverride = nil; AgentMailService.downloadOverride = nil; AgentMailService.installDirectoryOverride = nil }
        let v1 = try makeFixture(version: "1.0.0")
        let v2 = try makeFixture(version: "2.0.0")
        let vBadWrapped = try makeFixture(version: "3.0.0", failWrapped: true)
        let vBadDirect = try makeFixture(version: "4.0.0", failDirect: true)
        let v1name = AgentMailService.versionedName(version: "1.0.0", sha256: v1.binarySHA)
        let v2name = AgentMailService.versionedName(version: "2.0.0", sha256: v2.binarySHA)
        let fm = FileManager.default

        func freshDir() -> URL {
            let d = tempDir("bin")
            AgentMailService.installDirectoryOverride = d
            return d
        }
        func txState(_ dir: URL) -> String? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("agentmail.tx.json")),
                  let tx = try? JSONDecoder.iso.decode(AgentMailService.Transaction.self, from: data) else { return nil }
            return tx.state
        }

        // Fresh install.
        var dir = freshDir()
        useFixture(v1)
        var failure = await AgentMailService.installAgentMailBinary()
        check("fresh install succeeds", failure == nil, failure ?? "")
        check("published pair: wrapper + versioned binary, no tx, no staging", entries(dir) == ["agentmail", v1name], "\(entries(dir))")
        check("agentMailBrokerInstalled true and the wrapper answers", AgentMailService.agentMailBrokerInstalled() && wrapperAnswers(dir, "1.0.0"))
        check("wrapper target is the versioned path", AgentMailService.wrapperTarget(try Data(contentsOf: dir.appendingPathComponent("agentmail"))) == dir.appendingPathComponent(v1name).path)

        // Upgrade.
        useFixture(v2)
        failure = await AgentMailService.installAgentMailBinary()
        check("upgrade succeeds; previous binary removed, new pair live", failure == nil && entries(dir) == ["agentmail", v2name] && wrapperAnswers(dir, "2.0.0"), "\(failure ?? "") \(entries(dir))")

        // Existing versioned binary shortcut (matching hash) and mismatch.
        useFixture(v1)
        failure = await AgentMailService.installAgentMailBinary()
        var st = stat()
        lstat(dir.appendingPathComponent(v1name).path, &st)
        let inodeBefore = st.st_ino
        useFixture(v1)
        failure = await AgentMailService.installAgentMailBinary()
        lstat(dir.appendingPathComponent(v1name).path, &st)
        check("existing versioned file with matching hash: metadata written, binary not renamed over (inode unchanged), commit proceeds", failure == nil && st.st_ino == inodeBefore && txState(dir) == nil && wrapperAnswers(dir, "1.0.0"))
        try Data("garbage".utf8).write(to: dir.appendingPathComponent(v2name))
        useFixture(v2)
        failure = await AgentMailService.installAgentMailBinary()
        check("existing file with the expected name and wrong content → fails closed, byte-identical, no metadata",
              (failure ?? "").contains("unexpected content") && (try? String(contentsOf: dir.appendingPathComponent(v2name), encoding: .utf8)) == "garbage" && txState(dir) == nil && wrapperAnswers(dir, "1.0.0"))
        unlink(dir.appendingPathComponent(v2name).path)

        // Staged smoke failure never touches the published pair.
        useFixture(vBadDirect)
        let before = dirHash(dir)
        failure = await AgentMailService.installAgentMailBinary()
        check("staged binary failing its smoke test → published pair untouched", (failure ?? "").contains("failed to run") && dirHash(dir) == before)

        // Published-wrapper smoke failure on an upgrade → one atomic rollback.
        useFixture(vBadWrapped)
        failure = await AgentMailService.installAgentMailBinary()
        check("published wrapper failing → rolled back: previous wrapper restored, old binary intact, answers --version", (failure ?? "").contains("previous installation was restored") && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(failure ?? "") \(entries(dir))")

        // Fresh-install rollback: no prior installation.
        dir = freshDir()
        useFixture(vBadWrapped)
        failure = await AgentMailService.installAgentMailBinary()
        check("fresh install whose published wrapper fails → back to no installation", failure != nil && entries(dir).isEmpty && !AgentMailService.agentMailBrokerInstalled(), "\(entries(dir))")

        // Legacy fixture: unversioned agentmail-bin + old wrapper.
        dir = freshDir()
        try "#!/bin/sh\necho agentmail legacy\n".write(to: dir.appendingPathComponent("agentmail-bin"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("agentmail-bin").path)
        try AgentMailService.wrapperScript(adaPath: "/usr/bin/true", realBinaryPath: dir.appendingPathComponent("agentmail-bin").path).write(to: dir.appendingPathComponent("agentmail"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("agentmail").path)
        check("legacy pair counts as installed", AgentMailService.agentMailBrokerInstalled() && wrapperAnswers(dir, "legacy"))
        useFixture(v1)
        failure = await AgentMailService.installAgentMailBinary()
        check("legacy install upgrades and leaves no legacy file", failure == nil && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(entries(dir))")

        // Rotation (checkpoint throws) at every point, from a working install.
        struct Abort: Error {}
        for n in 1...9 {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            useFixture(v2)
            var calls = 0
            let f = await AgentMailService.installAgentMailBinary(checkpoint: { calls += 1; if calls == n { throw Abort() } })
            if calls < n { break }   // fewer checkpoints than n: the install completed
            let live = (try? Data(contentsOf: dir.appendingPathComponent("agentmail"))).flatMap(AgentMailService.wrapperTarget)
            let liveOK = live != nil && fm.fileExists(atPath: live!)
            let repaired = await AgentMailService.repairTransaction()
            let answers = wrapperAnswers(dir, "1.0.0") || wrapperAnswers(dir, "2.0.0")
            check("checkpoint abort #\(n): aborted (\(f != nil)), live wrapper complete with an existing target, repair settles, no tx/staging left, wrapper answers",
                  f != nil && liveOK && txState(dir) == nil && !entries(dir).contains { $0.hasPrefix(".agentmail-staging") } && answers && repaired != .busy,
                  "\(f ?? "nil") entries=\(entries(dir)) repair=\(repaired)")
        }
        // Rotation during a slow download → transfer cancelled, staging gone, old pair untouched.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let gate = AsyncGate()
            useFixture(v2, slow: gate)
            let task = Task { await AgentMailService.installAgentMailBinary() }
            try? await Task.sleep(nanoseconds: 200_000_000)
            task.cancel()
            gate.open()
            let f = await task.value
            check("cancellation during the download → install failed, staging gone, old pair answers", f != nil && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(f ?? "") \(entries(dir))")
        }

        // Crash injection (subprocess) at every point, then repair.
        for point in ["after-metadata", "after-binary", "after-committing", "after-swap", "after-committed"] {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", point, "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let crashed = p.terminationStatus != 0
            let stateBefore = txState(dir)
            let liveTarget = (try? Data(contentsOf: dir.appendingPathComponent("agentmail"))).flatMap(AgentMailService.wrapperTarget)
            let liveIntact = liveTarget != nil && fm.fileExists(atPath: liveTarget!)
            // Doctor reports, never mutates.
            let hashBefore = dirHash(dir)
            let report = AgentMailService.transactionReport()
            check("crash at \(point): process died, tx state \(stateBefore ?? "nil"), live wrapper intact, doctor reports without mutating",
                  crashed && stateBefore != nil && liveIntact && (report ?? "").contains("interrupted") && dirHash(dir) == hashBefore, "state=\(stateBefore ?? "nil") report=\(report ?? "nil")")
            let outcome = await AgentMailService.repairTransaction()
            let expectedVersion: String
            switch point {
            case "after-swap", "after-committed": expectedVersion = "2.0.0"
            default: expectedVersion = "1.0.0"
            }
            check("repair after \(point): settled, no tx, wrapper answers \(expectedVersion), no orphan binary",
                  { if case .settled = outcome { return true }; return false }() && txState(dir) == nil && wrapperAnswers(dir, expectedVersion)
                  && entries(dir) == ["agentmail", expectedVersion == "2.0.0" ? v2name : v1name], "\(outcome) \(entries(dir))")
        }
        // Crash after the rollback swap, before cleanup (upgrade whose wrapper fails).
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", "after-rollback-swap", "--dir", dir.path, "--fixture", vBadWrapped.archive.path, "--sums", vBadWrapped.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "3.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let stateBefore = txState(dir)
            let outcome = await AgentMailService.repairTransaction()
            check("crash after the rollback swap: old wrapper live, metadata \(stateBefore ?? "nil"), repair removes the new binary and the old wrapper answers",
                  stateBefore == "committing" && { if case .settled = outcome { return true }; return false }() && entries(dir) == ["agentmail", v1name] && wrapperAnswers(dir, "1.0.0"), "\(outcome) \(entries(dir))")
        }
        // Hand-edited wrapper under committing → fail closed.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: selfPath)
            p.arguments = ["__quicksetup-selftest", "--agentmail-crash", "after-committing", "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path]
            var env = ProcessInfo.processInfo.environment
            env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            try "#!/bin/sh\nexec '/somewhere/else' \"$@\"\n".write(to: dir.appendingPathComponent("agentmail"), atomically: true, encoding: .utf8)
            let hashBefore = dirHash(dir)
            let outcome = await AgentMailService.repairTransaction()
            check("hand-edited wrapper under committing → repair fails closed, deletes nothing, prints instructions",
                  { if case .failedClosed(let why) = outcome { return why.contains("does not match") }; return false }() && dirHash(dir) == hashBefore && txState(dir) == "committing", "\(outcome)")
            check("doctor keeps reporting it", (AgentMailService.transactionReport() ?? "").contains("interrupted"))
        }
        // Invalid metadata: absolute path, .., symlink at the named path, bad hash.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let good = AgentMailService.Transaction(state: "staged", newBinary: v2name, newSHA256: v2.binarySHA, newWrapperSHA256: String(repeating: "a", count: 64), previousWrapper: nil, previousBinary: v1name, startedAt: Date())
            func writeTx(_ tx: AgentMailService.Transaction) throws {
                try JSONEncoder.iso.encode(tx).write(to: dir.appendingPathComponent("agentmail.tx.json"))
            }
            var tx = good; tx.newBinary = "/tmp/agentmail-bin-2.0.0-" + String(v2.binarySHA.prefix(12))
            try writeTx(tx)
            var hash = dirHash(dir)
            var outcome = await AgentMailService.repairTransaction()
            check("metadata with an absolute path → refused, nothing deleted", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            tx = good; tx.previousBinary = "../agentmail-bin"
            try writeTx(tx)
            hash = dirHash(dir)
            outcome = await AgentMailService.repairTransaction()
            check("metadata with a .. segment → refused", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            tx = good
            try writeTx(tx)
            symlink("/etc/hosts", dir.appendingPathComponent(v2name).path)
            hash = dirHash(dir)
            outcome = await AgentMailService.repairTransaction()
            check("symlink at the named path → refused, link untouched", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            unlink(dir.appendingPathComponent(v2name).path)
            tx = good; tx.previousWrapper = .init(bytesB64: Data("x".utf8).base64EncodedString(), sha256: String(repeating: "b", count: 64), mode: 493)
            try writeTx(tx)
            hash = dirHash(dir)
            outcome = await AgentMailService.repairTransaction()
            check("previous wrapper bytes not matching their hash → refused", { if case .failedClosed = outcome { return true }; return false }() && dirHash(dir) == hash)
            unlink(dir.appendingPathComponent("agentmail.tx.json").path)
            check("validBasename rules", AgentMailService.validBasename("agentmail-bin") && AgentMailService.validBasename(v1name) && !AgentMailService.validBasename("agentmail") && !AgentMailService.validBasename("agentmail-bin-x-zz") && !AgentMailService.validBasename("../x") && !AgentMailService.validBasename(""))
        }
        // Locks.
        do {
            dir = freshDir()
            useFixture(v1)
            _ = await AgentMailService.installAgentMailBinary()
            let fd = open(dir.appendingPathComponent(".agentmail.lock").path, O_RDWR | O_CREAT, 0o600)
            check("lock file present after an install", fd >= 0)
            flock(fd, LOCK_EX)
            useFixture(v2)
            let busy = await AgentMailService.installAgentMailBinary()
            check("installer while the lock is held → 'in progress', nothing changed", (busy ?? "").contains("in progress") && entries(dir) == ["agentmail", v1name])
            let repairBusy = await AgentMailService.repairTransaction()
            check("repair while the lock is held → busy", repairBusy == .busy)
            check("doctor while the lock is held → 'in progress', no state read", (AgentMailService.transactionReport() ?? "").contains("in progress"))
            flock(fd, LOCK_UN); close(fd)
            unlink(dir.appendingPathComponent(".agentmail.lock").path)
            symlink("/tmp/whatever", dir.appendingPathComponent(".agentmail.lock").path)
            let sym = await AgentMailService.installAgentMailBinary()
            let symRepair = await AgentMailService.repairTransaction()
            check("symlink planted at the lock path → every path refuses", (sym ?? "").contains("refused") && { if case .failedClosed = symRepair { return true }; return false }(), "\(sym ?? "") \(symRepair)")
            unlink(dir.appendingPathComponent(".agentmail.lock").path)
            // Two installer processes at once: exactly one runs.
            let procs: [Process] = (0..<2).map { _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: selfPath)
                p.arguments = ["__quicksetup-selftest", "--agentmail-install", "--dir", dir.path, "--fixture", v2.archive.path, "--sums", v2.sums.path, "--hold-seconds", "1.5"]
                var env = ProcessInfo.processInfo.environment
                env["BRIGLIA_SELFTEST_AM_VERSION"] = "2.0.0"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                return p
            }
            for p in procs { try p.run() }
            var outputs: [String] = []
            for p in procs {
                let data = (p.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                outputs.append(String(data: data, encoding: .utf8) ?? "")
            }
            let successes = outputs.filter { $0.contains("OK") }.count
            let inProgress = outputs.filter { $0.contains("in progress") }.count
            check("two concurrent installers: exactly one runs, the other reports in progress; result consistent", successes == 1 && inProgress == 1 && wrapperAnswers(dir, "2.0.0") && txState(dir) == nil, "\(outputs)")
        }
    }
}
