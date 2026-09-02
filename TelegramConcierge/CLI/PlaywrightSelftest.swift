import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden deterministic battery for the lockfile-managed Playwright install
/// (`ManagedPlaywright`, `BrowserAutomationBootstrap.ensureConfigured`,
/// `MCPRegistry.updateManagedPlaywrightEntry`, the profile bundle's logical
/// representation, doctor findings). Everything runs under an isolated XDG
/// root with a fake `node` (python3 behind a shell shim), a fake `npm`
/// driven by a control file, and a fake stdio MCP server standing in for
/// `cli.js`; the real config is never touched and no network is used.
///
/// `--live` additionally runs the REAL bootstrap (bundled manifests, real
/// npm ci against the registry, real handshake) into the isolated root —
/// CI runs it where Node is present.
///
/// `--child-run <spec>` is the crash-injection driver: the battery spawns
/// this binary with a crash point, then again without, and asserts
/// convergence from the filesystem. Development builds only (release
/// builds refuse, like `__migrate-run`).
struct PlaywrightSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__playwright-selftest",
        abstract: "Internal: verify the managed Playwright install.",
        shouldDisplay: false
    )

    static let childRefusalText = "__playwright-selftest --child-run is a development-build command"

    @Option(name: .customLong("child-run"), help: .hidden)
    var childRun: String?

    @Flag(name: .customLong("live"), help: .hidden)
    var live = false

    func run() async throws {
        if let childRun {
            guard MigrationRunCommand.isDevelopmentBuild() else {
                print(Self.childRefusalText)
                throw ExitCode(2)
            }
            try await Self.runChild(specPath: childRun)
            return
        }
        // Isolate BEFORE anything touches StoragePaths.
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("briglia-playwright-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        setenv("XDG_CONFIG_HOME", tempRoot.path, 1)
        setenv("XDG_DATA_HOME", tempRoot.path, 1)
        setenv("TMPDIR", tempRoot.path + "/", 1)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        if live {
            try await Self.runLive(tempRoot: tempRoot, check: check)
        } else {
            try await Self.runBattery(tempRoot: tempRoot, check: check)
        }
        print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }

    // MARK: - Fixtures

    struct Fixtures {
        let root: URL
        let nodeDir: URL
        let controlFile: URL
        let npmLog: URL
        let goodCli: URL
        let brokenCli: URL
        let python: String

        var configFile: URL { StoragePaths.configRoot.appendingPathComponent("mcp.json") }
        var layout: ManagedPlaywright.Layout { ManagedPlaywright.Layout() }

        func setControl(_ dict: [String: Any]) throws {
            var full = dict
            full["log"] = npmLog.path
            if full["cliSource"] == nil { full["cliSource"] = goodCli.path }
            let data = try JSONSerialization.data(withJSONObject: full)
            try data.write(to: controlFile)
        }

        func npmInvocations() -> [[String: Any]] {
            guard let text = try? String(contentsOf: npmLog, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }

        func manifests(version: String, salt: String) -> ManagedPlaywright.Manifests {
            let pkg = "{\"name\":\"fixture\",\"dependencies\":{\"@playwright/mcp\":\"\(version)\"}}"
            let lock = """
            {"name":"fixture","lockfileVersion":3,"requires":true,"packages":{"":{"name":"fixture"},
            "node_modules/@playwright/mcp":{"version":"\(version)","resolved":"https://registry.npmjs.org/@playwright/mcp/-/mcp-\(version).tgz","integrity":"sha512-\(salt)"}}}
            """
            return ManagedPlaywright.Manifests(packageJSON: Data(pkg.utf8), packageLock: Data(lock.utf8))
        }

        func environment() -> [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["FAKE_NPM_CONTROL"] = controlFile.path
            env["PATH"] = nodeDir.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            return env
        }

        func dependencies(manifests: ManagedPlaywright.Manifests,
                          flag: URL,
                          npmTimeout: TimeInterval = 60,
                          crash: ManagedPlaywright.CrashPoint? = nil,
                          reload: Bool = false,
                          log: @escaping @Sendable (String) -> Void = { _ in }) -> BrowserAutomationBootstrap.Dependencies {
            var deps = BrowserAutomationBootstrap.Dependencies()
            deps.layout = layout
            deps.manifests = { manifests }
            deps.flag = .file(flag)
            let dir = nodeDir.path
            deps.nodeDirectory = { (dir, nil) }
            deps.baseEnvironment = environment()
            deps.npmTimeout = npmTimeout
            deps.handshakeTimeout = 8
            deps.crashPoint = crash
            deps.reloadRegistry = reload
            deps.log = log
            return deps
        }
    }

    static func makeFixtures(root: URL) throws -> Fixtures {
        let fm = FileManager.default
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/bin/python3"]
            .first { fm.isExecutableFile(atPath: $0) } ?? "python3"
        let nodeDir = root.appendingPathComponent("fake-node", isDirectory: true)
        try fm.createDirectory(at: nodeDir, withIntermediateDirectories: true)
        func executable(_ url: URL, _ content: String) throws {
            try content.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try executable(nodeDir.appendingPathComponent("node"), """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo v22.0.0; exit 0; fi
        exec "\(python)" "$@"
        """)
        try executable(nodeDir.appendingPathComponent("npm"), "#!\(python)\n" + fakeNpmSource)
        let goodCli = root.appendingPathComponent("good-cli.js")
        try fakeServerSource.write(to: goodCli, atomically: true, encoding: .utf8)
        let brokenCli = root.appendingPathComponent("broken-cli.js")
        try "import sys\nsys.stderr.write('fixture: broken server\\n')\nsys.exit(1)\n".write(to: brokenCli, atomically: true, encoding: .utf8)
        return Fixtures(root: root, nodeDir: nodeDir,
                        controlFile: root.appendingPathComponent("npm-control.json"),
                        npmLog: root.appendingPathComponent("npm-log.jsonl"),
                        goodCli: goodCli, brokenCli: brokenCli, python: python)
    }

    // MARK: - Battery

    static func runBattery(tempRoot: URL, check report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let fm = FileManager.default
        let fx = try makeFixtures(root: tempRoot)
        let layout = fx.layout
        let flag = tempRoot.appendingPathComponent("auto-flag")
        // The registry resolves bare `node` through the process PATH.
        setenv("PATH", fx.nodeDir.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"), 1)

        func readConfigBytes() -> Data { fm.contents(atPath: fx.configFile.path) ?? Data() }
        func readConfigJSON() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: readConfigBytes()) as? [String: Any]) ?? [:]
        }
        func playwrightEntry() -> [String: Any]? {
            (readConfigJSON()["mcpServers"] as? [String: Any])?["playwright"] as? [String: Any]
        }
        func writeConfig(_ root: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try fm.createDirectory(at: fx.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fx.configFile)
        }
        func legacyEntry(extra: [String: Any] = [:]) -> [String: Any] {
            var e: [String: Any] = ["command": "npx", "args": ["@playwright/mcp@latest"]]
            for (k, v) in extra { e[k] = v }
            return e
        }
        func managedEntry(hash: String, extra: [String: Any] = [:]) -> [String: Any] {
            let inv = ManagedPlaywright.managedInvocation(hash: hash, layout: layout)
            var e: [String: Any] = ["command": inv.command, "args": inv.arguments, "managed": ManagedPlaywright.managedMarker(hash: hash)]
            for (k, v) in extra { e[k] = v }
            return e
        }
        func markerText(_ hash: String) -> String? {
            (try? String(contentsOf: layout.versionDirectory(hash: hash).appendingPathComponent(ManagedPlaywright.completionMarkerName), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func wideEntries(under dir: URL) -> [String] {
            var wide: [String] = []
            guard let e = fm.enumerator(atPath: dir.path) else { return ["(unreadable)"] }
            for case let rel as String in e {
                let path = dir.path + "/" + rel
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFLNK { continue }
                if st.st_mode & 0o077 != 0 { wide.append(rel) }
            }
            return wide
        }
        let mA = fx.manifests(version: "0.0.80", salt: "AAAA")
        let mB = fx.manifests(version: "0.0.81", salt: "BBBB")
        let mC = fx.manifests(version: "0.0.82", salt: "CCCC")
        let hA = mA.lockfileHash, hB = mB.lockfileHash, hC = mC.lockfileHash

        // MARK: 1. Manifests and shapes (pure)

        let bundled = try ManagedPlaywright.Manifests.bundled()
        check("1.1 bundled manifests load, lockfile passes the sanity rules, pin @playwright/mcp",
              bundled.lockfileProblems().isEmpty && bundled.pinnedVersion != nil && bundled.lockfileHash.count == 16,
              bundled.lockfileProblems().joined(separator: "; "))
        check("1.2 lockfile hash is deterministic and 16 lowercase hex",
              ManagedPlaywright.Manifests.hash(of: bundled.packageLock) == bundled.lockfileHash
              && bundled.lockfileHash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
              && hA != hB && hB != hC)
        let badLock = ManagedPlaywright.Manifests(packageJSON: Data(), packageLock: Data("""
        {"lockfileVersion":3,"packages":{"":{},"node_modules/@playwright/mcp":{"version":"1","resolved":"https://evil.example/x.tgz","integrity":"sha1-x","hasInstallScript":true}}}
        """.utf8))
        let badProblems = badLock.lockfileProblems()
        check("1.3 sanity rules reject a foreign registry, weak integrity and install scripts",
              badProblems.count == 3, badProblems.joined(separator: "; "))
        func cfg(_ command: String, _ args: [String], managed: String? = nil, disabled: Bool = false) -> MCPServerConfig {
            MCPServerConfig(name: "playwright", command: command, arguments: args, disabled: disabled, managed: managed)
        }
        let inv = ManagedPlaywright.managedInvocation(hash: hA, layout: layout)
        check("1.4 shape table: absent / legacy / managed / edited / malformed marker / user / disabled",
              ManagedPlaywright.shape(of: nil, layout: layout) == .absent
              && ManagedPlaywright.shape(of: cfg("npx", ["@playwright/mcp@latest"]), layout: layout) == .legacyAuto
              && ManagedPlaywright.shape(of: cfg(inv.command, inv.arguments, managed: "playwright@\(hA)"), layout: layout) == .managed(hash: hA)
              && ManagedPlaywright.shape(of: cfg(inv.command, inv.arguments + ["--headless"], managed: "playwright@\(hA)"), layout: layout) == .managedEdited
              && ManagedPlaywright.shape(of: cfg(inv.command, inv.arguments, managed: "playwright@nothex"), layout: layout) == .managedEdited
              && ManagedPlaywright.shape(of: cfg("npx", ["@playwright/mcp@latest", "--headless"]), layout: layout) == .userAuthored
              && ManagedPlaywright.shape(of: cfg("npx", ["@playwright/mcp@latest"], disabled: true), layout: layout) == .disabled)
        check("1.5 directory-name parser accepts playwright-<16 hex> only",
              ManagedPlaywright.Layout.hash(fromDirectoryName: "playwright-\(hA)") == hA
              && ManagedPlaywright.Layout.hash(fromDirectoryName: "playwright-install.lock") == nil
              && ManagedPlaywright.Layout.hash(fromDirectoryName: "playwright.staging-x") == nil
              && ManagedPlaywright.Layout.hash(fromDirectoryName: "playwright-\(hA.uppercased())") == nil)
        let kept = ManagedPlaywright.managedConfig(hash: hA, layout: layout, basedOn: MCPServerConfig(
            name: "playwright", command: "npx", environment: ["FOO": "bar"], secretRefs: ["TOKEN"], description: "custom"))
        check("1.6 managedConfig keeps env, secretRefs and description of the previous entry",
              kept.environment == ["FOO": "bar"] && kept.secretRefs == ["TOKEN"] && kept.description == "custom"
              && kept.managed == "playwright@\(hA)" && kept.command == "node")

        // MARK: 2. Fresh install

        try fx.setControl(["mode": "ok"])
        let fresh = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag))
        check("2.1 fresh install (no mcp.json): configured + changed", fresh == .configured(hash: hA, changed: true), "\(fresh)")
        let e2 = playwrightEntry()
        check("2.2 entry is `node <cli.js>` with the managed marker and the default description",
              (e2?["command"] as? String) == "node"
              && (e2?["args"] as? [String]) == [layout.cliPath(hash: hA)]
              && (e2?["managed"] as? String) == "playwright@\(hA)"
              && (e2?["description"] as? String) == ManagedPlaywright.defaultDescription, "\(e2 ?? [:])")
        check("2.3 version directory carries the marker with the hash and the executable",
              markerText(hA) == hA && fm.fileExists(atPath: layout.cliPath(hash: hA)))
        let inv1 = fx.npmInvocations()
        check("2.4 npm ci ran once, in a staging directory holding both manifests, with --ignore-scripts, under umask 077",
              inv1.count == 1
              && (inv1.first?["args"] as? [String])?.first == "ci"
              && ((inv1.first?["args"] as? [String]) ?? []).contains("--ignore-scripts")
              && ((inv1.first?["cwd"] as? String) ?? "").contains("playwright.staging-")
              && (inv1.first?["manifests"] as? Bool) == true
              && (inv1.first?["umask"] as? Int) == 0o077, "\(inv1)")
        let leftovers = layout.leftovers()
        check("2.5 no staging or corrupt directory remains; lock file and mcp/ are owner-only; nothing wide under mcp/",
              leftovers.staging.isEmpty && leftovers.corrupt.isEmpty
              && wideEntries(under: layout.mcpRoot).isEmpty
              && (try? fm.attributesOfItem(atPath: layout.installLock.path)[.posixPermissions] as? Int) == 0o600,
              "\(leftovers) wide=\(wideEntries(under: layout.mcpRoot))")
        check("2.6 auto-configured flag set; status file says ready",
              fm.fileExists(atPath: flag.path)
              && ManagedPlaywright.readStatus(layout: layout)?.outcome == "ready"
              && ManagedPlaywright.readStatus(layout: layout)?.hash == hA)
        check("2.7 startup sweep finds nothing to tighten under the roots after the install",
              PrivateStorage.sweep(apply: true).tightened == 0)

        // MARK: 3. Reuse

        let before3 = readConfigBytes()
        let again = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag))
        check("3.1 second start: verified and reused, config untouched, npm not run again",
              again == .configured(hash: hA, changed: false) && readConfigBytes() == before3 && fx.npmInvocations().count == 1, "\(again)")

        // MARK: 4. Legacy switch preserves everything else

        try writeConfig([
            "extra": ["kept": true],
            "mcpServers": [
                "playwright": legacyEntry(extra: ["env": ["FOO": "bar"], "description": "custom", "secretRefs": ["TOKEN"], "note": "unknown key"]),
                "other": ["command": "uvx", "args": ["thing"], "x": 1],
            ],
        ])
        let switched = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag))
        let root4 = readConfigJSON()
        let e4 = playwrightEntry()
        let other4 = (root4["mcpServers"] as? [String: Any])?["other"] as? [String: Any]
        check("4.1 legacy `npx @playwright/mcp@latest` entry switched to the managed invocation",
              switched == .configured(hash: hA, changed: true)
              && (e4?["command"] as? String) == "node" && (e4?["managed"] as? String) == "playwright@\(hA)", "\(switched)")
        check("4.2 env, description, secretRefs and an unknown key of the entry survive; other servers and top-level keys untouched",
              (e4?["env"] as? [String: String]) == ["FOO": "bar"] && (e4?["description"] as? String) == "custom"
              && (e4?["secretRefs"] as? [String]) == ["TOKEN"] && (e4?["note"] as? String) == "unknown key"
              && (other4?["command"] as? String) == "uvx" && (other4?["x"] as? Int) == 1
              && ((root4["extra"] as? [String: Any])?["kept"] as? Bool) == true, "\(root4)")
        check("4.3 the switch reused the verified install (npm still ran once)", fx.npmInvocations().count == 1)
        check("4.4 mcp.json is 0600", (try? fm.attributesOfItem(atPath: fx.configFile.path)[.posixPermissions] as? Int) == 0o600)

        // MARK: 5. Left alone

        for (label, entry, expected) in [
            ("5.1 user-authored entry (own args)", legacyEntry(extra: ["args": ["@playwright/mcp@latest", "--headless"]]), BrowserAutomationBootstrap.Outcome.leftAlone(.userAuthored)),
            ("5.2 managed marker with edited args", managedEntry(hash: hA, extra: ["args": [layout.cliPath(hash: hA), "--headless"]]), .leftAlone(.managedEdited)),
            ("5.3 disabled legacy entry", legacyEntry(extra: ["disabled": true]), .leftAlone(.disabled)),
        ] {
            try writeConfig(["mcpServers": ["playwright": entry]])
            let bytes = readConfigBytes()
            let count = fx.npmInvocations().count
            let outcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
            check("\(label): left alone, file byte-identical, no install attempted",
                  outcome == expected && readConfigBytes() == bytes && fx.npmInvocations().count == count
                  && !fm.fileExists(atPath: layout.versionDirectory(hash: hB).path), "\(outcome)")
        }
        try? fm.removeItem(at: fx.configFile)
        try "1".write(to: flag, atomically: true, encoding: .utf8)
        let cfgDir = fx.configFile.deletingLastPathComponent()
        try fm.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        // mcp.json present (other servers only) + flag set = deliberate removal.
        try writeConfig(["mcpServers": ["other": ["command": "uvx", "args": []]]])
        let notWanted = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag))
        check("5.4 entry removed on purpose (flag set, mcp.json present): not re-added",
              notWanted == .notWanted && playwrightEntry() == nil, "\(notWanted)")

        // MARK: 6. Version bump keeps the old install

        try writeConfig(["mcpServers": ["playwright": managedEntry(hash: hA)]])
        let bump = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("6.1 a build that pins another lockfile installs it and re-points the entry",
              bump == .configured(hash: hB, changed: true) && (playwrightEntry()?["managed"] as? String) == "playwright@\(hB)"
              && markerText(hB) == hB && fx.npmInvocations().count == 2, "\(bump)")
        check("6.2 the previous immutable install is kept (never auto-deleted)", markerText(hA) == hA)
        let doc6 = ManagedPlaywright.doctorFindings(configs: MCPRegistry.loadConfigsFromDisk(), layout: layout, bundledHash: hB)
        check("6.3 doctor lists playwright-\(hA) as unreferenced and the managed entry as healthy",
              doc6.contains { $0.text.contains("unreferenced") && $0.text.contains("playwright-\(hA)") }
              && doc6.contains { $0.text.contains("managed install playwright-\(hB)") && !$0.problem }, doc6.map(\.text).joined(separator: " | "))

        // MARK: 7. Corrupt install: quarantined, rebuilt, never referenced

        try fm.removeItem(atPath: layout.cliPath(hash: hB))
        let rebuilt = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        let corrupt7 = layout.leftovers().corrupt
        check("7.1 missing executable: directory quarantined as playwright.corrupt-*, rebuilt, entry still points at playwright-\(hB)",
              rebuilt == .configured(hash: hB, changed: false) && corrupt7.count == 1 && markerText(hB) == hB
              && (playwrightEntry()?["args"] as? [String]) == [layout.cliPath(hash: hB)] && fx.npmInvocations().count == 3, "\(rebuilt) \(corrupt7)")
        let cleaned = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("7.2 the following start removes the quarantined directory and reuses the rebuilt install",
              cleaned == .configured(hash: hB, changed: false) && layout.leftovers().corrupt.isEmpty && fx.npmInvocations().count == 3)
        // Marker naming another lockfile.
        try Data((hA + "\n").utf8).write(to: layout.versionDirectory(hash: hB).appendingPathComponent(ManagedPlaywright.completionMarkerName))
        let remarked = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("7.3 marker naming another lockfile: quarantined and rebuilt",
              remarked == .configured(hash: hB, changed: false) && markerText(hB) == hB && fx.npmInvocations().count == 4
              && layout.leftovers().corrupt.count == 1, "\(remarked)")
        _ = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        // Executable present but the server does not answer.
        try fm.removeItem(atPath: layout.cliPath(hash: hB))
        try fm.copyItem(at: fx.brokenCli, to: URL(fileURLWithPath: layout.cliPath(hash: hB)))
        let dead = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("7.4 executable that fails the handshake: quarantined and rebuilt",
              dead == .configured(hash: hB, changed: false) && fx.npmInvocations().count == 5 && layout.leftovers().corrupt.count == 1, "\(dead)")
        _ = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))

        // MARK: 8. Failed builds leave the previous state intact

        let before8 = readConfigBytes()
        for (label, control, needle) in [
            ("8.1 npm ci fails", ["mode": "fail"], "npm ci exited 1"),
            ("8.2 staged server fails its handshake", ["mode": "ok", "cliSource": fx.brokenCli.path], "failed verification"),
            ("8.3 staged tree has no executable", ["mode": "ok", "omitCli": true], "cli.js missing"),
        ] as [(String, [String: Any], String)] {
            try fx.setControl(control)
            let outcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mC, flag: flag))
            var reason = ""
            if case .failed(let r) = outcome { reason = r }
            check("\(label): failed with the reason, previous entry byte-identical, playwright-\(hB) intact, no staging or version dir left",
                  reason.contains(needle) && readConfigBytes() == before8 && markerText(hB) == hB
                  && layout.leftovers().staging.isEmpty && !fm.fileExists(atPath: layout.versionDirectory(hash: hC).path)
                  && ManagedPlaywright.readStatus(layout: layout)?.outcome == "failed", "\(outcome)")
        }

        // MARK: 9. Timeout terminates the whole process group

        let childPid = tempRoot.appendingPathComponent("npm-child.pid")
        try fx.setControl(["mode": "spawn-child-and-hang", "childPidFile": childPid.path])
        let t0 = Date()
        let timedOut = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mC, flag: flag, npmTimeout: 3))
        var reason9 = ""
        if case .failed(let r) = timedOut { reason9 = r }
        let grandchild = Int32((try? String(contentsOf: childPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        var grandchildGone = false
        if grandchild > 0 {
            for _ in 0..<40 {
                if kill(grandchild, 0) == -1 && errno == ESRCH { grandchildGone = true; break }
                // A reaped-by-init zombie still answers kill(0); check its state.
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !grandchildGone {
                // On Linux a killed grandchild re-parented to a subreaper may
                // linger as a zombie; /proc tells.
                if let status = try? String(contentsOfFile: "/proc/\(grandchild)/status", encoding: .utf8),
                   status.contains("State:\tZ") { grandchildGone = true }
            }
        }
        check("9.1 npm ci timeout: failed with 'timed out', within bounds, the grandchild of npm is gone, staging removed",
              reason9.contains("timed out") && !reason9.contains("could not be confirmed") && Date().timeIntervalSince(t0) < 30
              && grandchild > 0 && grandchildGone && layout.leftovers().staging.isEmpty, "\(timedOut) pid=\(grandchild) gone=\(grandchildGone)")
        let relock = try ManagedPlaywright.InstallLock.tryAcquire(layout.installLock)
        check("9.2 installation lock released after the timeout", relock != nil)
        relock?.release()

        // MARK: 10. Lock held by another live holder

        try fx.setControl(["mode": "ok"])
        let holder = try ManagedPlaywright.InstallLock.tryAcquire(layout.installLock)
        let before10 = readConfigBytes()
        let count10 = fx.npmInvocations().count
        let skipped = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mC, flag: flag))
        var skippedOK = false
        if case .skipped = skipped { skippedOK = true }
        check("10.1 lock held: skipped this start, no staging directory, no config write, no npm",
              skippedOK && layout.leftovers().staging.isEmpty && readConfigBytes() == before10 && fx.npmInvocations().count == count10
              && ManagedPlaywright.readStatus(layout: layout)?.outcome == "skipped", "\(skipped)")
        holder?.release()

        // MARK: 11. Orphans removed at the next start

        let orphanStaging = layout.mcpRoot.appendingPathComponent("playwright.staging-deadbeef")
        let orphanCorrupt = layout.mcpRoot.appendingPathComponent("playwright.corrupt-cafebabe")
        try fm.createDirectory(at: orphanStaging, withIntermediateDirectories: true)
        try fm.createDirectory(at: orphanCorrupt, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphanStaging.appendingPathComponent("file"))
        let doc11 = ManagedPlaywright.doctorFindings(configs: MCPRegistry.loadConfigsFromDisk(), layout: layout, bundledHash: hB)
        let after11 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("11.1 orphan staging and corrupt directories: listed by doctor, removed by the next start, install reused",
              doc11.contains { $0.text.contains("leftover") && $0.text.contains("playwright.staging-deadbeef") }
              && after11 == .configured(hash: hB, changed: false)
              && !fm.fileExists(atPath: orphanStaging.path) && !fm.fileExists(atPath: orphanCorrupt.path), "\(after11)")

        // MARK: 12. Hand-written reference to a missing managed directory

        try writeConfig(["mcpServers": ["playwright": managedEntry(hash: "0123456789abcdef")]])
        let repointed = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("12.1 managed entry naming a directory that does not exist: re-pointed to the verified install, nothing deleted",
              repointed == .configured(hash: hB, changed: true) && (playwrightEntry()?["managed"] as? String) == "playwright@\(hB)"
              && markerText(hA) == hA && markerText(hB) == hB, "\(repointed)")
        let docMissing = ManagedPlaywright.doctorFindings(
            configs: [MCPServerConfig(name: "playwright", command: "node", arguments: [layout.cliPath(hash: "0123456789abcdef")], managed: "playwright@0123456789abcdef")],
            layout: layout, bundledHash: hB)
        check("12.2 doctor flags a managed entry whose directory is missing", docMissing.contains { $0.problem && $0.text.contains("0123456789abcdef") })

        // MARK: 13. External edit while npm is running

        let started = tempRoot.appendingPathComponent("npm-started")
        let proceed = tempRoot.appendingPathComponent("npm-proceed")
        try fx.setControl(["mode": "wait-for", "startedFile": started.path, "waitFor": proceed.path])
        try writeConfig(["mcpServers": ["playwright": managedEntry(hash: hB)]])
        let depsC = fx.dependencies(manifests: mC, flag: flag)
        let task = Task { await BrowserAutomationBootstrap.ensureConfigured(dependencies: depsC) }
        var sawStart = false
        for _ in 0..<200 {
            if fm.fileExists(atPath: started.path) { sawStart = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The agent (file tools) or a human edits mcp.json mid-install: adds a
        // server and points playwright at the OLDER immutable version A.
        try writeConfig(["mcpServers": [
            "playwright": managedEntry(hash: hA, extra: ["description": "edited mid-install"]),
            "added": ["command": "uvx", "args": ["mid"]],
        ]])
        try Data("go".utf8).write(to: proceed)
        let mid = await task.value
        let root13 = readConfigJSON()
        let e13 = playwrightEntry()
        check("13.1 bootstrap re-reads at the switch: the mid-install edit survives (added server, description), entry moves A → C, A and B kept",
              sawStart && mid == .configured(hash: hC, changed: true)
              && ((root13["mcpServers"] as? [String: Any])?["added"] as? [String: Any])?["command"] as? String == "uvx"
              && (e13?["description"] as? String) == "edited mid-install" && (e13?["managed"] as? String) == "playwright@\(hC)"
              && markerText(hA) == hA && markerText(hB) == hB && markerText(hC) == hC, "\(mid) \(root13)")
        try? fm.removeItem(at: started); try? fm.removeItem(at: proceed)
        // Edited to a user-authored shape mid-install: the bootstrap leaves it alone.
        try fx.setControl(["mode": "wait-for", "startedFile": started.path, "waitFor": proceed.path])
        try writeConfig(["mcpServers": ["playwright": managedEntry(hash: hA)]])
        try fm.removeItem(at: layout.versionDirectory(hash: hC))
        let depsC2 = fx.dependencies(manifests: mC, flag: flag)
        let task2 = Task { await BrowserAutomationBootstrap.ensureConfigured(dependencies: depsC2) }
        for _ in 0..<200 {
            if fm.fileExists(atPath: started.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try writeConfig(["mcpServers": ["playwright": ["command": "/opt/my/own", "args": []]]])
        let bytes13 = readConfigBytes()
        try Data("go".utf8).write(to: proceed)
        let mid2 = await task2.value
        check("13.2 edited to a user-authored entry mid-install: install completes, entry left byte-identical",
              mid2 == .leftAlone(.userAuthored) && readConfigBytes() == bytes13 && markerText(hC) == hC, "\(mid2)")

        // MARK: 14. Profile bundle: logical representation

        try fx.setControl(["mode": "ok"])
        try writeConfig(["mcpServers": ["playwright": managedEntry(hash: hC, extra: ["env": ["FOO": "bar"]]), "other": ["command": "uvx", "args": ["x"]]]])
        let exported = try ProfileBundle.exportData()
        let exportedText = String(data: exported, encoding: .utf8) ?? ""
        let exportedRoot = try JSONSerialization.jsonObject(with: exported) as? [String: Any]
        let exportedPW = (exportedRoot?["mcpServers"] as? [String: Any])?["playwright"] as? [String: Any]
        check("14.1 export carries the managed marker only — no command, no args, no installation path",
              (exportedPW?["managed"] as? String) == "playwright@\(hC)" && exportedPW?["command"] == nil && exportedPW?["args"] == nil
              && (exportedPW?["env"] as? [String: String]) == ["FOO": "bar"] && !exportedText.contains(layout.mcpRoot.path), exportedText.prefix(300).description)
        try writeConfig(["mcpServers": ["other": ["command": "uvx", "args": ["x"]]]])
        let imported = try await ProfileBundle.importData(exported)
        let e14 = playwrightEntry()
        check("14.2 import on a machine that has that version resolves to the concrete managed entry",
              imported.mcpServersAdded.contains("playwright") && (e14?["command"] as? String) == "node"
              && (e14?["args"] as? [String]) == [layout.cliPath(hash: hC)] && (e14?["managed"] as? String) == "playwright@\(hC)"
              && (e14?["env"] as? [String: String]) == ["FOO": "bar"] && imported.warnings.isEmpty, "\(e14 ?? [:]) \(imported.warnings)")
        let (fallbackBundled, warnB) = ProfileBundle.resolveManagedPlaywright(
            marker: "playwright@0123456789abcdef", layout: layout, basedOn: nil, bundledHash: hC)
        check("14.3 unknown version but this build's pinned version installed: resolves to it with a warning",
              fallbackBundled.managed == "playwright@\(hC)" && warnB != nil, "\(fallbackBundled) \(warnB ?? "")")
        let emptyLayout = ManagedPlaywright.Layout(dataRoot: tempRoot.appendingPathComponent("nowhere"))
        let (fallbackLegacy, warnL) = ProfileBundle.resolveManagedPlaywright(
            marker: "playwright@\(hC)", layout: emptyLayout, basedOn: nil, bundledHash: hC)
        check("14.4 nothing installed locally: legacy auto shape (switched at the next start) with a warning — never a path that does not exist",
              fallbackLegacy.command == "npx" && fallbackLegacy.arguments == ["@playwright/mcp@latest"] && fallbackLegacy.managed == nil && warnL != nil)

        // MARK: 15. Registry reload after the switch

        try writeConfig(["mcpServers": ["playwright": legacyEntry()]])
        let live15 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mC, flag: flag, reload: true))
        let status15 = await MCPRegistry.shared.status()
        let tools15 = await MCPRegistry.shared.allToolDefinitions().map { $0.function.name }
        check("15.1 after the switch the registry runs the managed server: connected, mcp__playwright__browser_navigate available",
              live15 == .configured(hash: hC, changed: true)
              && status15.contains { $0.name == "playwright" && $0.connected && !$0.failed }
              && tools15.contains("mcp__playwright__browser_navigate"), "\(live15) \(status15) \(tools15)")
        await MCPRegistry.shared.shutdownAll()

        // MARK: 16. Crash injection (development builds only)

        if MigrationRunCommand.isDevelopmentBuild() {
            let manifestsDir = tempRoot.appendingPathComponent("manifests-crash", isDirectory: true)
            try fm.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
            try mA.packageJSON.write(to: manifestsDir.appendingPathComponent("package.json"))
            try mA.packageLock.write(to: manifestsDir.appendingPathComponent("package-lock.json"))
            let selfPath = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
            for point in ManagedPlaywright.CrashPoint.allCases {
                let caseRoot = tempRoot.appendingPathComponent("crash-\(point.rawValue)", isDirectory: true)
                let caseConfigRoot = caseRoot.appendingPathComponent("briglia", isDirectory: true)
                try fm.createDirectory(at: caseConfigRoot, withIntermediateDirectories: true)
                let caseConfig = caseConfigRoot.appendingPathComponent("mcp.json")
                let legacy = try JSONSerialization.data(withJSONObject: ["mcpServers": ["playwright": legacyEntry()]], options: [.sortedKeys])
                try legacy.write(to: caseConfig)
                let caseLayout = ManagedPlaywright.Layout(dataRoot: caseConfigRoot)
                let caseLog = caseRoot.appendingPathComponent("npm-log.jsonl")
                let caseControl = caseRoot.appendingPathComponent("npm-control.json")
                try JSONSerialization.data(withJSONObject: ["mode": "ok", "log": caseLog.path, "cliSource": fx.goodCli.path]).write(to: caseControl)
                func spec(crash: ManagedPlaywright.CrashPoint?) throws -> URL {
                    let url = caseRoot.appendingPathComponent("spec-\(crash?.rawValue ?? "run").json")
                    var dict: [String: Any] = [
                        "manifestsDir": manifestsDir.path, "nodeDir": fx.nodeDir.path,
                        "controlFile": caseControl.path, "flagFile": caseRoot.appendingPathComponent("flag").path,
                    ]
                    if let crash { dict["crashPoint"] = crash.rawValue }
                    try JSONSerialization.data(withJSONObject: dict).write(to: url)
                    return url
                }
                func runChild(crash: ManagedPlaywright.CrashPoint?) -> (Int32, String) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: selfPath)
                    p.arguments = ["__playwright-selftest", "--child-run", (try? spec(crash: crash))?.path ?? ""]
                    var env = ProcessInfo.processInfo.environment
                    env["XDG_CONFIG_HOME"] = caseRoot.path
                    env["XDG_DATA_HOME"] = caseRoot.path
                    env["TMPDIR"] = caseRoot.path + "/"
                    p.environment = env
                    let pipe = Pipe()
                    p.standardOutput = pipe; p.standardError = pipe
                    do { try p.run() } catch { return (-1, "\(error)") }
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    p.waitUntilExit()
                    return (p.terminationStatus, out)
                }
                func entry() -> [String: Any]? {
                    guard let data = fm.contents(atPath: caseConfig.path),
                          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    return (root["mcpServers"] as? [String: Any])?["playwright"] as? [String: Any]
                }
                func referencedDirValid() -> Bool {
                    guard let marker = entry()?["managed"] as? String, let hash = ManagedPlaywright.hash(fromMarker: marker) else { return false }
                    let text = try? String(contentsOf: caseLayout.versionDirectory(hash: hash).appendingPathComponent(ManagedPlaywright.completionMarkerName), encoding: .utf8)
                    return text?.trimmingCharacters(in: .whitespacesAndNewlines) == hash
                }
                let (crashStatus, crashOut) = runChild(crash: point)
                let isLegacy = (entry()?["command"] as? String) == "npx"
                let invariant = isLegacy || referencedDirValid()
                let stagingAfterCrash = caseLayout.leftovers().staging.count
                let (status, out) = runChild(crash: nil)
                let npmRuns = ((try? String(contentsOf: caseLog, encoding: .utf8)) ?? "").split(separator: "\n").count
                let converged = out.contains("OUTCOME: configured") && referencedDirValid()
                    && caseLayout.leftovers().staging.isEmpty && caseLayout.leftovers().corrupt.isEmpty
                    && ManagedPlaywright.readStatus(layout: caseLayout)?.outcome == "ready"
                let expectedRuns: Int
                let expectedChanged: Bool
                switch point {
                case .beforeInstall: expectedRuns = 1; expectedChanged = true
                case .afterInstall: expectedRuns = 2; expectedChanged = true       // staging orphaned, rebuilt
                case .afterRename, .afterParentFsync: expectedRuns = 1; expectedChanged = true  // reused
                case .afterConfigWrite: expectedRuns = 1; expectedChanged = false  // already switched
                }
                let changedOK = out.contains("changed: \(expectedChanged)")
                check("16.\(point.rawValue): crash exits 137, config never dangles (legacy or verified), next start converges (npm runs \(expectedRuns), changed \(expectedChanged))",
                      crashStatus == 137 && invariant && status == 0 && converged && npmRuns == expectedRuns && changedOK
                      && (point != .afterInstall || stagingAfterCrash == 1),
                      "crash=\(crashStatus) legacy=\(isLegacy) valid=\(referencedDirValid()) staging=\(stagingAfterCrash) run=\(status) npm=\(npmRuns) out=\(out.suffix(200)) crashOut=\(crashOut.suffix(120))")
            }
        } else {
            print("· 16 crash injection skipped (release build refuses --child-run)")
            let (refusal, text) = await Self.probeChildRefusal()
            check("16.0 release build refuses --child-run with exit 2", refusal == 2 && text.contains(Self.childRefusalText), "\(refusal) \(text)")
        }
    }

    static func probeChildRefusal() async -> (Int32, String) {
        let p = Process()
        p.executableURL = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        p.arguments = ["__playwright-selftest", "--child-run", "/dev/null"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    // MARK: - Child (crash-injection driver)

    static func runChild(specPath: String) async throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: specPath))
        guard let spec = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifestsDir = spec["manifestsDir"] as? String,
              let nodeDir = spec["nodeDir"] as? String,
              let controlFile = spec["controlFile"] as? String,
              let flagFile = spec["flagFile"] as? String else {
            print("bad spec"); throw ExitCode(1)
        }
        let manifests = try ManagedPlaywright.Manifests.load(from: URL(fileURLWithPath: manifestsDir))
        var deps = BrowserAutomationBootstrap.Dependencies()
        deps.layout = ManagedPlaywright.Layout()
        deps.manifests = { manifests }
        deps.flag = .file(URL(fileURLWithPath: flagFile))
        deps.nodeDirectory = { (nodeDir, nil) }
        var env = ProcessInfo.processInfo.environment
        env["FAKE_NPM_CONTROL"] = controlFile
        env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        deps.baseEnvironment = env
        deps.handshakeTimeout = 8
        deps.reloadRegistry = false
        deps.crashPoint = (spec["crashPoint"] as? String).flatMap(ManagedPlaywright.CrashPoint.init(rawValue:))
        deps.log = { print("log: \($0)") }
        let outcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: deps)
        switch outcome {
        case .configured(let hash, let changed): print("OUTCOME: configured hash: \(hash) changed: \(changed)")
        default: print("OUTCOME: \(outcome)")
        }
    }

    // MARK: - Live (real npm, real registry, real node)

    static func runLive(tempRoot: URL, check report: (String, Bool, String) -> Void) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { report(label, ok, detail) }
        let resolved = ManagedPlaywright.resolveNodeDirectory()
        guard let nodeDir = resolved.directory else {
            print("· live: no usable Node found (\(resolved.reason ?? "")) — skipped")
            return
        }
        let manifests = try ManagedPlaywright.Manifests.bundled()
        print("· live: node at \(nodeDir), pinned @playwright/mcp \(manifests.pinnedVersion ?? "?") (lockfile \(manifests.lockfileHash))")
        var deps = BrowserAutomationBootstrap.Dependencies()
        deps.flag = .file(tempRoot.appendingPathComponent("flag"))
        deps.nodeDirectory = { (nodeDir, nil) }
        deps.reloadRegistry = false
        deps.log = { print("log: \($0)") }
        let t0 = Date()
        let outcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: deps)
        let layout = ManagedPlaywright.Layout()
        let hash = manifests.lockfileHash
        let pkg = layout.versionDirectory(hash: hash).appendingPathComponent(ManagedPlaywright.packageRelativePath)
        let installedVersion = (try? JSONSerialization.jsonObject(with: Data(contentsOf: pkg)) as? [String: Any])?["version"] as? String
        check("live.1 real npm ci against the committed lockfile + real handshake: configured in \(Int(Date().timeIntervalSince(t0)))s",
              outcome == .configured(hash: hash, changed: true), "\(outcome)")
        check("live.2 installed @playwright/mcp is the pinned version", installedVersion == manifests.pinnedVersion, "\(installedVersion ?? "nil")")
        check("live.3 nothing group/other-readable under mcp/", PrivateStorage.sweep(apply: false).tightened == 0)
        let again = await BrowserAutomationBootstrap.ensureConfigured(dependencies: deps)
        check("live.4 second start reuses without npm", again == .configured(hash: hash, changed: false), "\(again)")
    }

    // MARK: - Fake npm

    static let fakeNpmSource = """
    import json, os, shutil, subprocess, sys, time
    ctl = json.load(open(os.environ["FAKE_NPM_CONTROL"]))
    old = os.umask(0)
    os.umask(old)
    manifests = os.path.exists("package.json") and os.path.exists("package-lock.json")
    with open(ctl["log"], "a") as f:
        f.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd(), "umask": old, "manifests": manifests}) + "\\n")
    mode = ctl.get("mode", "ok")
    if mode == "fail":
        sys.stderr.write("npm ERR! fixture failure\\n")
        sys.exit(1)
    if mode == "hang":
        time.sleep(600)
    if mode == "spawn-child-and-hang":
        child = subprocess.Popen(["sleep", "600"])
        with open(ctl["childPidFile"], "w") as f:
            f.write(str(child.pid))
        time.sleep(600)
    if mode == "wait-for":
        with open(ctl["startedFile"], "w") as f:
            f.write("1")
        while not os.path.exists(ctl["waitFor"]):
            time.sleep(0.05)
    if sys.argv[1:2] != ["ci"] or not manifests:
        sys.stderr.write("fixture: expected `npm ci` in a directory holding both manifests\\n")
        sys.exit(3)
    lock = json.load(open("package-lock.json"))
    version = lock["packages"]["node_modules/@playwright/mcp"]["version"]
    d = os.path.join(os.getcwd(), "node_modules", "@playwright", "mcp")
    os.makedirs(d)
    os.makedirs(os.path.join(os.getcwd(), "node_modules", ".bin"))
    with open(os.path.join(d, "package.json"), "w") as f:
        json.dump({"name": "@playwright/mcp", "version": version}, f)
    if not ctl.get("omitCli"):
        shutil.copy(ctl["cliSource"], os.path.join(d, "cli.js"))
        os.chmod(os.path.join(d, "cli.js"), 0o700)
    with open(os.path.join(os.getcwd(), "node_modules", ".bin", "playwright-mcp"), "w") as f:
        f.write("#!/bin/sh\\nexit 0\\n")
    """

    /// Minimal stdio MCP server standing in for `@playwright/mcp`'s cli.js
    /// (run as `node cli.js` — `node` is the python shim).
    static let fakeServerSource = """
    import json, sys
    tools = [
        {"name": "browser_navigate", "description": "Navigate to a URL", "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}}},
        {"name": "browser_click", "description": "Click", "inputSchema": {"type": "object", "properties": {"ref": {"type": "string"}}}},
        {"name": "browser_snapshot", "description": "Snapshot", "inputSchema": {"type": "object", "properties": {}}},
    ]
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if "id" not in msg:
            continue
        method = msg.get("method")
        if method == "initialize":
            res = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-playwright", "version": "0"}}
        elif method == "tools/list":
            res = {"tools": tools}
        elif method == "tools/call":
            res = {"content": [{"type": "text", "text": "ok"}]}
        else:
            res = {}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": res}) + "\\n")
        sys.stdout.flush()
    """
}
