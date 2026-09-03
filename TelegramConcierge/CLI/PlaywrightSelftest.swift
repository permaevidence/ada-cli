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
        // Line-buffered stdout even when redirected (CI logs show the last
        // completed check if the battery ever stalls).
        setvbuf(stdout, nil, _IOLBF, 0)
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
        func managedEntry(token hash: String, extra: [String: Any] = [:]) -> [String: Any] {
            let inv = ManagedPlaywright.managedInvocation(token: hash, layout: layout)
            var e: [String: Any] = ["command": inv.command, "args": inv.arguments, "managed": ManagedPlaywright.managedMarker(token: hash)]
            for (k, v) in extra { e[k] = v }
            return e
        }
        func markerText(_ token: String) -> String? {
            (try? String(contentsOf: layout.versionDirectory(token: token).appendingPathComponent(ManagedPlaywright.completionMarkerName), encoding: .utf8))?
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
        let inv = ManagedPlaywright.managedInvocation(token: hA, layout: layout)
        check("1.4 shape table: absent / legacy / managed / edited / malformed marker / user / disabled",
              ManagedPlaywright.shape(of: nil, layout: layout) == .absent
              && ManagedPlaywright.shape(of: cfg("npx", ["@playwright/mcp@latest"]), layout: layout) == .legacyAuto
              && ManagedPlaywright.shape(of: cfg(inv.command, inv.arguments, managed: "playwright@\(hA)"), layout: layout) == .managed(token: hA)
              && ManagedPlaywright.shape(of: cfg(inv.command, inv.arguments + ["--headless"], managed: "playwright@\(hA)"), layout: layout) == .managedEdited
              && ManagedPlaywright.shape(of: cfg(inv.command, inv.arguments, managed: "playwright@nothex"), layout: layout) == .managedEdited
              && ManagedPlaywright.shape(of: cfg("npx", ["@playwright/mcp@latest", "--headless"]), layout: layout) == .userAuthored
              && ManagedPlaywright.shape(of: cfg("npx", ["@playwright/mcp@latest"], disabled: true), layout: layout) == .disabled)
        check("1.5 directory-name parser accepts playwright-<16 hex> and playwright-<16 hex>-r<8 hex> only",
              ManagedPlaywright.Layout.token(fromDirectoryName: "playwright-\(hA)") == hA
              && ManagedPlaywright.Layout.token(fromDirectoryName: "playwright-\(hA)-rdeadbeef") == "\(hA)-rdeadbeef"
              && ManagedPlaywright.Layout.lockfileHash(ofToken: "\(hA)-rdeadbeef") == hA
              && ManagedPlaywright.Layout.token(fromDirectoryName: "playwright-\(hA)-rdeadbee") == nil
              && ManagedPlaywright.Layout.token(fromDirectoryName: "playwright-\(hA)-xdeadbeef") == nil
              && ManagedPlaywright.Layout.token(fromDirectoryName: "playwright-install.lock") == nil
              && ManagedPlaywright.Layout.token(fromDirectoryName: "playwright.staging-x") == nil
              && ManagedPlaywright.Layout.token(fromDirectoryName: "playwright-\(hA.uppercased())") == nil)
        let kept = ManagedPlaywright.managedConfig(token: hA, layout: layout, basedOn: MCPServerConfig(
            name: "playwright", command: "npx", environment: ["FOO": "bar"], secretRefs: ["TOKEN"], description: "custom"))
        check("1.6 managedConfig keeps env, secretRefs and description of the previous entry",
              kept.environment == ["FOO": "bar"] && kept.secretRefs == ["TOKEN"] && kept.description == "custom"
              && kept.managed == "playwright@\(hA)" && kept.command == "node")

        // MARK: 2. Fresh install

        try fx.setControl(["mode": "ok"])
        let fresh = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag))
        check("2.1 fresh install (no mcp.json): configured + changed", fresh == .configured(token: hA, changed: true), "\(fresh)")
        let e2 = playwrightEntry()
        check("2.2 entry is `node <cli.js>` with the managed marker and the default description",
              (e2?["command"] as? String) == "node"
              && (e2?["args"] as? [String]) == [layout.cliPath(token: hA)]
              && (e2?["managed"] as? String) == "playwright@\(hA)"
              && (e2?["description"] as? String) == ManagedPlaywright.defaultDescription, "\(e2 ?? [:])")
        check("2.3 version directory carries the marker with the hash and the executable",
              markerText(hA) == hA && fm.fileExists(atPath: layout.cliPath(token: hA)))
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
              && ManagedPlaywright.readStatus(layout: layout)?.token == hA)
        check("2.7 startup sweep finds nothing to tighten under the roots after the install",
              PrivateStorage.sweep(apply: true).tightened == 0)

        // MARK: 3. Reuse

        let before3 = readConfigBytes()
        let again = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag))
        check("3.1 second start: verified and reused, config untouched, npm not run again",
              again == .configured(token: hA, changed: false) && readConfigBytes() == before3 && fx.npmInvocations().count == 1, "\(again)")

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
              switched == .configured(token: hA, changed: true)
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
            ("5.2 managed marker with edited args", managedEntry(token: hA, extra: ["args": [layout.cliPath(token: hA), "--headless"]]), .leftAlone(.managedEdited)),
            ("5.3 disabled legacy entry", legacyEntry(extra: ["disabled": true]), .leftAlone(.disabled)),
        ] {
            try writeConfig(["mcpServers": ["playwright": entry]])
            let bytes = readConfigBytes()
            let count = fx.npmInvocations().count
            let outcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
            check("\(label): left alone, file byte-identical, no install attempted",
                  outcome == expected && readConfigBytes() == bytes && fx.npmInvocations().count == count
                  && !fm.fileExists(atPath: layout.versionDirectory(token: hB).path), "\(outcome)")
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

        try writeConfig(["mcpServers": ["playwright": managedEntry(token: hA)]])
        let bump = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("6.1 a build that pins another lockfile installs it and re-points the entry",
              bump == .configured(token: hB, changed: true) && (playwrightEntry()?["managed"] as? String) == "playwright@\(hB)"
              && markerText(hB) == hB && fx.npmInvocations().count == 2, "\(bump)")
        check("6.2 the previous immutable install is kept (never auto-deleted)", markerText(hA) == hA)
        let doc6 = ManagedPlaywright.doctorFindings(configs: MCPRegistry.loadConfigsFromDisk(), layout: layout, bundledHash: hB)
        check("6.3 doctor lists playwright-\(hA) as unreferenced and the managed entry as healthy",
              doc6.contains { $0.text.contains("unreferenced") && $0.text.contains("playwright-\(hA)") }
              && doc6.contains { $0.text.contains("managed install playwright-\(hB)") && !$0.problem }, doc6.map(\.text).joined(separator: " | "))

        // MARK: 7. Invalid installs: the referenced tree is never renamed before the switch

        func referencedToken() -> String? {
            (playwrightEntry()?["managed"] as? String).flatMap(ManagedPlaywright.token(fromMarker:))
        }
        var tB = hB
        try fm.removeItem(atPath: layout.cliPath(token: tB))
        let repaired = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        let t7 = referencedToken() ?? "?"
        check("7.1 referenced install missing its executable: replacement built under playwright-<hash>-r…, entry switched to it, old tree quarantined AFTER the switch",
              repaired == .configured(token: t7, changed: true) && t7.hasPrefix(hB + "-r") && markerText(t7) == hB
              && (playwrightEntry()?["args"] as? [String]) == [layout.cliPath(token: t7)]
              && !fm.fileExists(atPath: layout.versionDirectory(token: tB).path) && layout.leftovers().corrupt.count == 1
              && fx.npmInvocations().count == 3, "\(repaired) token=\(t7) corrupt=\(layout.leftovers().corrupt)")
        tB = t7
        let cleaned = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("7.2 the following start removes the quarantined directory and reuses the replacement",
              cleaned == .configured(token: tB, changed: false) && layout.leftovers().corrupt.isEmpty && fx.npmInvocations().count == 3, "\(cleaned)")
        // Marker naming another lockfile.
        try Data((hA + "\n").utf8).write(to: layout.versionDirectory(token: tB).appendingPathComponent(ManagedPlaywright.completionMarkerName))
        let remarked = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        let t73 = referencedToken() ?? "?"
        check("7.3 marker naming another lockfile: replacement built, switched, old quarantined",
              remarked == .configured(token: t73, changed: true) && t73 != tB && markerText(t73) == hB && fx.npmInvocations().count == 4
              && layout.leftovers().corrupt.count == 1, "\(remarked)")
        tB = t73
        _ = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        // Executable present but the server does not answer.
        try fm.removeItem(atPath: layout.cliPath(token: tB))
        try fm.copyItem(at: fx.brokenCli, to: URL(fileURLWithPath: layout.cliPath(token: tB)))
        let dead = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        let t74 = referencedToken() ?? "?"
        check("7.4 executable that fails the handshake: replacement built, switched, old quarantined",
              dead == .configured(token: t74, changed: true) && t74 != tB && fx.npmInvocations().count == 5 && layout.leftovers().corrupt.count == 1, "\(dead)")
        tB = t74
        _ = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        // Codex round 1 #2: the referenced tree is invalid AND the rebuild
        // fails — the configuration must still point at the (invalid but
        // present) tree, nothing renamed, nothing dangling.
        try fm.removeItem(atPath: layout.cliPath(token: tB))
        try fx.setControl(["mode": "fail"])
        let before75 = readConfigBytes()
        let stuck = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        var stuckReason = ""
        if case .failed(let r) = stuck { stuckReason = r }
        check("7.5 referenced tree invalid + rebuild fails: failed, config byte-identical, the referenced directory still present (not quarantined), no corrupt, no staging",
              stuckReason.contains("npm ci exited 1") && readConfigBytes() == before75
              && fm.fileExists(atPath: layout.versionDirectory(token: tB).path) && layout.leftovers().corrupt.isEmpty
              && layout.leftovers().staging.isEmpty && fx.npmInvocations().count == 6, "\(stuck)")
        try fx.setControl(["mode": "ok"])
        let healed = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        let t76 = referencedToken() ?? "?"
        check("7.6 next start with npm working: replacement built, switched, old quarantined",
              healed == .configured(token: t76, changed: true) && t76 != tB && markerText(t76) == hB
              && !fm.fileExists(atPath: layout.versionDirectory(token: tB).path) && layout.leftovers().corrupt.count == 1, "\(healed)")
        tB = t76
        _ = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        // Crash between switch and quarantine, simulated: an invalid
        // UNREFERENCED tree of the same lockfile is quarantined at the next
        // start; a VALID unreferenced one of the same lockfile is kept.
        let staleInvalid = layout.versionDirectory(token: hB + "-rdead0000")
        try fm.createDirectory(at: staleInvalid, withIntermediateDirectories: true)
        try Data((hB + "\n").utf8).write(to: staleInvalid.appendingPathComponent(ManagedPlaywright.completionMarkerName))
        let staleValid = layout.versionDirectory(token: hB + "-rcafe0000")
        try fm.copyItem(at: layout.versionDirectory(token: tB), to: staleValid)
        let settled = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("7.7 unreferenced trees of the current lockfile: the invalid one is quarantined, the valid one kept, the referenced one reused",
              settled == .configured(token: tB, changed: false) && !fm.fileExists(atPath: staleInvalid.path)
              && fm.fileExists(atPath: staleValid.path) && layout.leftovers().corrupt.count == 1 && fx.npmInvocations().count == 7, "\(settled)")
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
            check("\(label): failed with the reason, previous entry byte-identical, playwright-\(tB) intact, no staging or version dir left",
                  reason.contains(needle) && readConfigBytes() == before8 && markerText(tB) == hB
                  && layout.leftovers().staging.isEmpty && !fm.fileExists(atPath: layout.versionDirectory(token: hC).path)
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

        // MARK: 11. A pre-existing staging tree is parked, never deleted (Codex round 4)

        let orphanStaging = layout.stagingDirectory()
        let orphanCorrupt = layout.mcpRoot.appendingPathComponent("playwright.corrupt-cafebabe")
        try fm.createDirectory(at: orphanStaging, withIntermediateDirectories: true)
        try fm.createDirectory(at: orphanCorrupt, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: orphanStaging.appendingPathComponent("file"))
        let doc11 = ManagedPlaywright.doctorFindings(configs: MCPRegistry.loadConfigsFromDisk(), layout: layout, bundledHash: hB)
        let after11 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        var after11OK = false
        if case .skipped(let r) = after11, r.contains("interrupted install") { after11OK = true }
        let manual11 = layout.leftovers().manual.first { !$0.hasSuffix(".json") } ?? "?"
        check("11.1 orphan staging found at start: doctor flags it, the start parks it (contents intact) and refuses; the quarantined directory is left for later",
              doc11.contains { $0.problem && $0.text.contains(orphanStaging.lastPathComponent) }
              && after11OK && !fm.fileExists(atPath: orphanStaging.path)
              && fm.fileExists(atPath: layout.manualDirectory(stem: manual11).appendingPathComponent("file").path)
              && fm.fileExists(atPath: orphanCorrupt.path), "\(after11) \(layout.leftovers())")
        for name in layout.leftovers().manual { try fm.removeItem(at: layout.mcpRoot.appendingPathComponent(name)) }
        let after11b = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("11.2 after manual removal: the quarantined directory is removed, the install reused",
              after11b == .configured(token: tB, changed: false) && !fm.fileExists(atPath: orphanCorrupt.path), "\(after11b)")

        // MARK: 12. Hand-written reference to a missing managed directory

        try writeConfig(["mcpServers": ["playwright": managedEntry(token: "0123456789abcdef")]])
        let repointed = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mB, flag: flag))
        check("12.1 managed entry naming a directory that does not exist: re-pointed to the verified install, nothing deleted",
              repointed == .configured(token: tB, changed: true) && (playwrightEntry()?["managed"] as? String) == "playwright@\(tB)"
              && markerText(hA) == hA && markerText(tB) == hB, "\(repointed)")
        let docMissing = ManagedPlaywright.doctorFindings(
            configs: [MCPServerConfig(name: "playwright", command: "node", arguments: [layout.cliPath(token: "0123456789abcdef")], managed: "playwright@0123456789abcdef")],
            layout: layout, bundledHash: hB)
        check("12.2 doctor flags a managed entry whose directory is missing", docMissing.contains { $0.problem && $0.text.contains("0123456789abcdef") })

        // MARK: 13. External edit while npm is running

        let started = tempRoot.appendingPathComponent("npm-started")
        let proceed = tempRoot.appendingPathComponent("npm-proceed")
        try fx.setControl(["mode": "wait-for", "startedFile": started.path, "waitFor": proceed.path])
        try writeConfig(["mcpServers": ["playwright": managedEntry(token: tB)]])
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
            "playwright": managedEntry(token: hA, extra: ["description": "edited mid-install"]),
            "added": ["command": "uvx", "args": ["mid"]],
        ]])
        try Data("go".utf8).write(to: proceed)
        let mid = await task.value
        let root13 = readConfigJSON()
        let e13 = playwrightEntry()
        check("13.1 bootstrap re-reads at the switch: the mid-install edit survives (added server, description), entry moves A → C, A and B kept",
              sawStart && mid == .configured(token: hC, changed: true)
              && ((root13["mcpServers"] as? [String: Any])?["added"] as? [String: Any])?["command"] as? String == "uvx"
              && (e13?["description"] as? String) == "edited mid-install" && (e13?["managed"] as? String) == "playwright@\(hC)"
              && markerText(hA) == hA && markerText(tB) == hB && markerText(hC) == hC, "\(mid) \(root13)")
        try? fm.removeItem(at: started); try? fm.removeItem(at: proceed)
        // Edited to a user-authored shape mid-install: the bootstrap leaves it alone.
        try fx.setControl(["mode": "wait-for", "startedFile": started.path, "waitFor": proceed.path])
        try writeConfig(["mcpServers": ["playwright": managedEntry(token: hA)]])
        try fm.removeItem(at: layout.versionDirectory(token: hC))
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

        // Codex round 1 #4: an agent file-tool edit between the switch's
        // decision and its write. The file tools take the config lock, so
        // the edit BLOCKS until the switch has written, then lands on top.
        try fx.setControl(["mode": "ok"])
        try writeConfig(["mcpServers": ["playwright": legacyEntry()]])
        let seamState = SeamState()
        MCPRegistry.testHookBeforeManagedConfigWrite = {
            let thread = Thread {
                let path = fx.configFile.path
                _ = try? MCPAgentRouting.withLockIfRoutingFile(path) {
                    seamState.enteredLock = Date()
                    // What edit_file does inside the lock: read, modify, write.
                    var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fx.configFile)) as? [String: Any]) ?? [:]
                    var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
                    servers["seam"] = ["command": "uvx", "args": ["seam"]]
                    root["mcpServers"] = servers
                    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                    try PrivateStorage.writeAtomically(data, to: fx.configFile)
                }
                seamState.done = true
            }
            thread.start()
            Thread.sleep(forTimeInterval: 0.7)
            seamState.hookLeft = Date()
        }
        let seamOutcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mC, flag: flag))
        MCPRegistry.testHookBeforeManagedConfigWrite = nil
        for _ in 0..<100 where !seamState.done { try await Task.sleep(nanoseconds: 50_000_000) }
        let root133 = readConfigJSON()
        check("13.3 injected file-tool edit between decision and write: blocked by the config lock until the switch landed, then applied on top — both survive",
              seamOutcome == .configured(token: hC, changed: true) && seamState.done
              && seamState.enteredLock != nil && seamState.hookLeft != nil && seamState.enteredLock! >= seamState.hookLeft!
              && (playwrightEntry()?["managed"] as? String) == "playwright@\(hC)"
              && ((root133["mcpServers"] as? [String: Any])?["seam"] as? [String: Any])?["command"] as? String == "uvx",
              "\(seamOutcome) entered=\(String(describing: seamState.enteredLock)) left=\(String(describing: seamState.hookLeft)) \(root133)")

        // MARK: 14. Profile bundle: logical representation

        try fx.setControl(["mode": "ok"])
        try writeConfig(["mcpServers": ["playwright": managedEntry(token: hC, extra: ["env": ["FOO": "bar"]]), "other": ["command": "uvx", "args": ["x"]]]])
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
              && (e14?["args"] as? [String]) == [layout.cliPath(token: hC)] && (e14?["managed"] as? String) == "playwright@\(hC)"
              && (e14?["env"] as? [String: String]) == ["FOO": "bar"] && imported.warnings.isEmpty, "\(e14 ?? [:]) \(imported.warnings)")
        let (fallbackBundled, warnB) = ProfileBundle.resolveManagedPlaywright(
            marker: "playwright@0123456789abcdef", layout: layout, basedOn: nil, bundledHash: hC)
        check("14.3 unknown version but this build's pinned version installed: resolves to it with a warning",
              fallbackBundled?.managed == "playwright@\(hC)" && warnB != nil, "\(String(describing: fallbackBundled)) \(warnB ?? "")")
        let emptyLayout = ManagedPlaywright.Layout(dataRoot: tempRoot.appendingPathComponent("nowhere"))
        let (fallbackNone, warnL) = ProfileBundle.resolveManagedPlaywright(
            marker: "playwright@\(hC)", layout: emptyLayout, basedOn: nil, bundledHash: hC)
        check("14.4 nothing installed locally: the entry is skipped with a warning — an importer never writes @latest",
              fallbackNone == nil && (warnL ?? "").contains("skipped"))
        // Through importData with the real bundle hash (not installed in this root): skipped, no @latest anywhere.
        try writeConfig(["mcpServers": ["other": ["command": "uvx", "args": ["x"]]]])
        let foreignBundle = try JSONSerialization.data(withJSONObject: [
            "version": ProfileBundle.currentVersion, "mcpServers": ["playwright": ["managed": "playwright@0123456789abcdef"]]])
        let importedNone = try await ProfileBundle.importData(foreignBundle)
        let text145 = String(data: readConfigBytes(), encoding: .utf8) ?? ""
        check("14.5 importData with no local install: playwright entry absent, warning present, file free of @latest",
              playwrightEntry() == nil && importedNone.warnings.contains { $0.contains("skipped") } && !text145.contains("@latest")
              && !importedNone.mcpServersAdded.contains("playwright"), "\(importedNone.warnings) \(text145)")

        // MARK: 15. Registry reload after the switch

        try writeConfig(["mcpServers": ["playwright": legacyEntry()]])
        let live15 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mC, flag: flag, reload: true))
        let status15 = await MCPRegistry.shared.status()
        let tools15 = await MCPRegistry.shared.allToolDefinitions().map { $0.function.name }
        check("15.1 after the switch the registry runs the managed server: connected, mcp__playwright__browser_navigate available",
              live15 == .configured(token: hC, changed: true)
              && status15.contains { $0.name == "playwright" && $0.connected && !$0.failed }
              && tools15.contains("mcp__playwright__browser_navigate"), "\(live15) \(status15) \(tools15)")
        await MCPRegistry.shared.shutdownAll()

        // MARK: 17. Registry reload during an in-flight bootstrap (Codex round 1 #1)

        let slowPid = tempRoot.appendingPathComponent("slow.pid")
        try writeConfig(["mcpServers": ["slowpoke": [
            "command": "node", "args": [fx.goodCli.path],
            "env": ["FAKE_MCP_DELAY": "3", "FAKE_MCP_PIDFILE": slowPid.path]]]])
        let inFlight = Task { await MCPRegistry.shared.allToolDefinitions() }
        var slowStarted = false
        for _ in 0..<100 {
            if fm.fileExists(atPath: slowPid.path) { slowStarted = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try writeConfig(["mcpServers": ["fast": ["command": "node", "args": [fx.goodCli.path]]]])
        await MCPRegistry.shared.reloadFromDisk()
        _ = await inFlight.value
        let status17 = await MCPRegistry.shared.status()
        let slow = Int32((try? String(contentsOf: slowPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
        var slowGone = false
        for _ in 0..<100 {
            if slow > 0 && kill(slow, 0) == -1 && errno == ESRCH { slowGone = true; break }
            if let st = try? String(contentsOfFile: "/proc/\(slow)/status", encoding: .utf8), st.contains("State:\tZ") { slowGone = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check("17.1 reload while a bootstrap is mid-handshake: the stale bootstrap publishes nothing, its server is shut down, only the new generation is registered",
              slowStarted && status17.map(\.name) == ["fast"] && status17.allSatisfy { $0.connected && !$0.failed } && slowGone,
              "started=\(slowStarted) status=\(status17) slowPid=\(slow) gone=\(slowGone)")
        await MCPRegistry.shared.shutdownAll()

        // MARK: 18. Unconfirmed process group → permanent parking (Codex rounds 2–3)

        // A sacrificial process stands in for a surviving npm descendant: the
        // enumeration override reports it (by its REAL identity) as the only
        // live member of whatever group is asked about, as long as it runs.
        func spawnSacrificial() async throws -> (Process, ManagedPlaywright.ProcessGroups.Identity) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sleep")
            proc.arguments = ["600"]
            try proc.run()
            var identity: ManagedPlaywright.ProcessGroups.Identity? = nil
            for _ in 0..<50 {
                if let m = ManagedPlaywright.ProcessGroups.members(of: proc.processIdentifier)?.first(where: { $0.identity.pid == proc.processIdentifier }) {
                    identity = m.identity; break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let identity else { throw ManagedPlaywright.ManagedError("could not enumerate the sacrificial process") }
            return (proc, identity)
        }
        // corelibs Foundation's `terminate()`/`waitUntilExit()` can hang on
        // Linux for a child it no longer tracks cleanly; end the sacrificial
        // processes with a direct SIGKILL and a bounded poll instead.
        func reap(_ proc: Process) async {
            kill(proc.processIdentifier, SIGKILL)
            for _ in 0..<100 where proc.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        let (sac1, id1) = try await spawnSacrificial()
        check("18.0 real enumeration: the sacrificial process is found with pid + start time; a wrong start time does not match; our own group reads alive",
              id1.pid == sac1.processIdentifier && id1.startTime > 0
              && ManagedPlaywright.ProcessGroups.stillAlive([id1]) == [id1]
              && ManagedPlaywright.ProcessGroups.stillAlive([.init(pid: id1.pid, startTime: id1.startTime &+ 1)]) == []
              && ManagedPlaywright.processGroupHasLiveMembers(getpgrp()))
        ManagedPlaywright.ProcessGroups.membersOverride = { _ in sac1.isRunning ? [.init(identity: id1, zombie: false)] : [] }
        try fx.setControl(["mode": "spawn-child-and-hang", "childPidFile": childPid.path])
        try writeConfig(["mcpServers": ["playwright": managedEntry(token: hC)]])
        let mD = fx.manifests(version: "0.0.83", salt: "DDDD")
        let before18 = readConfigBytes()
        let parked = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mD, flag: flag, npmTimeout: 2))
        var parkReason = ""
        if case .failed(let r) = parked { parkReason = r }
        let left18 = layout.leftovers()
        let stem18 = left18.manual.first { !$0.hasSuffix(".json") && !$0.hasSuffix(".hold") } ?? "?"
        let info18 = fm.contents(atPath: layout.manualInfoURL(stem: stem18).path)
            .flatMap { try? JSONDecoder.iso.decode(ManagedPlaywright.ManualRecoveryInfo.self, from: $0) }
        check("18.1 timeout with a live member: staging PARKED as playwright.manual-*, no staging left, information file names the member's identity and the boot id, config untouched",
              parkReason.contains("parked as playwright.manual-") && left18.staging.isEmpty && left18.manual.count == 2
              && fm.fileExists(atPath: layout.manualDirectory(stem: stem18).appendingPathComponent("package.json").path)
              && info18?.members == [id1] && info18?.enumerationFailed == false && info18?.bootID == ManagedPlaywright.ProcessGroups.bootID()
              && readConfigBytes() == before18, "\(parked) \(left18) \(String(describing: info18))")
        let count18 = fx.npmInvocations().count
        let refused = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mD, flag: flag))
        var refusedOK = false
        if case .skipped(let r) = refused, r.contains("manual recovery") { refusedOK = true }
        let doc18 = ManagedPlaywright.doctorFindings(configs: MCPRegistry.loadConfigsFromDisk(), layout: layout, bundledHash: mD.lockfileHash)
        check("18.2 while parked: later bootstraps refuse (nothing staged, no npm, nothing signalled), doctor flags it with the live pid",
              refusedOK && sac1.isRunning && fx.npmInvocations().count == count18
              && doc18.contains { $0.problem && $0.text.contains("manual recovery") && ($0.hint ?? "").contains("\(id1.pid)") }, "\(refused) \(doc18.map(\.text))")
        await reap(sac1)
        let stillRefused = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mD, flag: flag))
        var stillOK = false
        if case .skipped(let r) = stillRefused, r.contains("manual recovery") { stillOK = true }
        let doc18b = ManagedPlaywright.doctorFindings(configs: MCPRegistry.loadConfigsFromDisk(), layout: layout, bundledHash: mD.lockfileHash)
        check("18.3 recorded process gone: still refused (nothing is automatic), doctor now says none alive",
              stillOK && layout.leftovers().manual.count == 2 && doc18b.contains { $0.problem && $0.text.contains("none of the 1 recorded") }, "\(stillRefused) \(doc18b.map(\.text))")
        ManagedPlaywright.ProcessGroups.membersOverride = nil
        for name in layout.leftovers().manual { try fm.removeItem(at: layout.mcpRoot.appendingPathComponent(name)) }
        try fx.setControl(["mode": "ok"])
        let unparked = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mD, flag: flag))
        check("18.4 removed by hand: the next start installs", unparked == .configured(token: mD.lockfileHash, changed: true), "\(unparked)")
        // Enumeration failure is "alive": the probe falls back to kill(-pgid, 0),
        // where only ESRCH means gone; parking records that enumeration failed.
        ManagedPlaywright.ProcessGroups.membersOverride = { _ in nil }
        let deadGroup: Int32 = {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["0"]
            try? p.run(); p.waitUntilExit(); return p.processIdentifier
        }()
        let probeStaging = layout.stagingDirectory()
        try fm.createDirectory(at: probeStaging, withIntermediateDirectories: true)
        let note18 = ManagedPlaywright.parkStaging(probeStaging, layout: layout, processGroup: getpgrp(), reason: "fixture")
        let stem18b = layout.leftovers().manual.first { !$0.hasSuffix(".json") && !$0.hasSuffix(".hold") } ?? "?"
        let info18b = fm.contents(atPath: layout.manualInfoURL(stem: stem18b).path)
            .flatMap { try? JSONDecoder.iso.decode(ManagedPlaywright.ManualRecoveryInfo.self, from: $0) }
        check("18.5 enumeration failure: our own group still reads alive (kill probe), a finished group reads gone only through ESRCH; parking records the failed enumeration",
              ManagedPlaywright.processGroupHasLiveMembers(getpgrp()) && !ManagedPlaywright.processGroupHasLiveMembers(deadGroup)
              && note18.contains("parked as") && info18b?.enumerationFailed == true && info18b?.members == nil && !fm.fileExists(atPath: probeStaging.path),
              "\(note18) \(String(describing: info18b))")
        ManagedPlaywright.ProcessGroups.membersOverride = nil
        for name in layout.leftovers().manual { try fm.removeItem(at: layout.mcpRoot.appendingPathComponent(name)) }
        // Park rename fails: the tree stays in place and still blocks; a later
        // start parks it once the rename works again.
        let (sac2, id2) = try await spawnSacrificial()
        ManagedPlaywright.ProcessGroups.membersOverride = { _ in sac2.isRunning ? [.init(identity: id2, zombie: false)] : [] }
        ManagedPlaywright.parkRenameOverride = { _, _ in errno = EIO; return -1 }
        try fx.setControl(["mode": "spawn-child-and-hang", "childPidFile": childPid.path])
        let mE = fx.manifests(version: "0.0.84", salt: "EEEE")
        let held = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag, npmTimeout: 2))
        var heldReason = ""
        if case .failed(let r) = held { heldReason = r }
        let left18c = layout.leftovers()
        _ = ManagedPlaywright.removeLeftovers(layout: layout)
        check("18.6 park rename fails: the staging tree stays in place (nothing else written), cleanup leaves it alone",
              heldReason.contains("stays in place") && left18c.staging.count == 1 && left18c.manual.isEmpty
              && fm.fileExists(atPath: layout.mcpRoot.appendingPathComponent(left18c.staging[0]).path), "\(held) \(left18c)")
        let heldRefused = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        var heldRefusedOK = false
        if case .skipped(let r) = heldRefused, r.contains("interrupted install") && r.contains("stays in place") { heldRefusedOK = true }
        check("18.7 next start (rename still failing): refused as an interrupted install, tree still in place",
              heldRefusedOK && fm.fileExists(atPath: layout.mcpRoot.appendingPathComponent(left18c.staging[0]).path), "\(heldRefused)")
        ManagedPlaywright.parkRenameOverride = nil
        let parkedLater = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        var parkedLaterOK = false
        if case .skipped(let r) = parkedLater, r.contains("interrupted install") && r.contains("parked as") { parkedLaterOK = true }
        check("18.8 rename works again: parked with an information file (no process group known), still refused",
              parkedLaterOK && layout.leftovers().staging.isEmpty && layout.leftovers().manual.count == 2, "\(parkedLater) \(layout.leftovers())")
        ManagedPlaywright.ProcessGroups.membersOverride = nil
        await reap(sac2)
        for name in layout.leftovers().manual + layout.leftovers().staging { try fm.removeItem(at: layout.mcpRoot.appendingPathComponent(name)) }
        try fx.setControl(["mode": "ok"])
        let unheld = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        check("18.9 after manual removal the install proceeds", unheld == .configured(token: mE.lockfileHash, changed: true), "\(unheld)")
        let hE = mE.lockfileHash

        // MARK: 19. Quarantine re-checks the configuration under the lock (Codex round 2 #2)

        // Candidate scan: an invalid UNREFERENCED tree of the current lockfile
        // gets referenced by an edit in the window before the config lock.
        let strayE = hE + "-rdead2222"
        let strayDir = layout.versionDirectory(token: strayE)
        try fm.createDirectory(at: strayDir, withIntermediateDirectories: true)
        try Data((hE + "\n").utf8).write(to: strayDir.appendingPathComponent(ManagedPlaywright.completionMarkerName))
        var hookSeen: String? = nil
        ManagedPlaywright.testHookBeforeQuarantineLock = { token in
            hookSeen = token
            try? writeConfig(["mcpServers": ["playwright": managedEntry(token: token)]])
        }
        let scan19 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        ManagedPlaywright.testHookBeforeQuarantineLock = nil
        check("19.1 candidate-scan quarantine: an edit that references the tree in the window is honoured — the tree stays, the entry is later switched to the valid install",
              hookSeen == strayE && fm.fileExists(atPath: strayDir.path) && scan19 == .configured(token: hE, changed: true)
              && (playwrightEntry()?["managed"] as? String) == "playwright@\(hE)", "\(scan19) hook=\(hookSeen ?? "nil")")
        let scan19b = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        check("19.2 …and the next start, with the tree unreferenced again, quarantines it",
              scan19b == .configured(token: hE, changed: false) && !fm.fileExists(atPath: strayDir.path) && layout.leftovers().corrupt.count == 1, "\(scan19b)")
        _ = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        // Post-switch quarantine: the referenced invalid tree is pointed at
        // again by an edit between the switch and the quarantine.
        try fm.removeItem(atPath: layout.cliPath(token: hE))
        ManagedPlaywright.testHookBeforeQuarantineLock = { token in
            try? writeConfig(["mcpServers": ["playwright": managedEntry(token: token)]])
        }
        let post19 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        ManagedPlaywright.testHookBeforeQuarantineLock = nil
        let newE = layout.installedTokens().first { $0.hasPrefix(hE + "-r") && $0 != strayE } ?? "?"
        check("19.3 post-switch quarantine: the edit pointing back at the old tree wins — old tree kept, replacement built and kept",
              fm.fileExists(atPath: layout.versionDirectory(token: hE).path) && markerText(newE) == hE
              && (playwrightEntry()?["managed"] as? String) == "playwright@\(hE)" && layout.leftovers().corrupt.isEmpty,
              "\(post19) new=\(newE) tokens=\(layout.installedTokens())")
        // Next start: referenced tree still invalid → replaced (the existing valid -r tree is reused), old quarantined.
        let heal19 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        check("19.4 next start repairs it: the valid replacement is reused, the entry switched, the old tree quarantined",
              heal19 == .configured(token: newE, changed: true) && !fm.fileExists(atPath: layout.versionDirectory(token: hE).path)
              && layout.leftovers().corrupt.count == 1, "\(heal19)")

        // Fail-closed quarantine (Codex round 3 #2): uncertainty keeps the tree.
        let qTok = hE + "-rfeed0000"
        let qDir = layout.versionDirectory(token: qTok)
        func plantQ() throws {
            try? fm.removeItem(at: qDir)
            try fm.createDirectory(at: qDir, withIntermediateDirectories: true)
            try Data((hE + "\n").utf8).write(to: qDir.appendingPathComponent(ManagedPlaywright.completionMarkerName))
        }
        try plantQ()
        try Data("{not json".utf8).write(to: fx.configFile)
        let qMalformed = ManagedPlaywright.quarantineIfUnreferenced(token: qTok, layout: layout)
        var qMalformedOK = false
        if case .failed(let r) = qMalformed, r.contains("cannot be read or parsed") { qMalformedOK = true }
        check("19.5 malformed mcp.json: not quarantined, failure names the reason", qMalformedOK && fm.fileExists(atPath: qDir.path), "\(qMalformed)")
        try writeConfig(["mcpServers": ["playwright": managedEntry(token: qTok, extra: ["args": [layout.cliPath(token: qTok), "--headless"]])]])
        check("19.6 managed marker with edited args: referenced, kept",
              ManagedPlaywright.quarantineIfUnreferenced(token: qTok, layout: layout) == .referenced && fm.fileExists(atPath: qDir.path))
        try writeConfig(["mcpServers": ["playwright": ["command": "/usr/bin/env", "args": ["node", layout.cliPath(token: qTok)]]]])
        check("19.7 user-authored entry naming the installation path: referenced, kept",
              ManagedPlaywright.quarantineIfUnreferenced(token: qTok, layout: layout) == .referenced && fm.fileExists(atPath: qDir.path))
        try writeConfig(["mcpServers": ["playwright": legacyEntry(), "mirror": ["command": layout.versionDirectory(token: qTok).appendingPathComponent("node_modules/.bin/playwright-mcp").path, "args": []]]])
        check("19.8 another server whose command lives under the installation: referenced, kept",
              ManagedPlaywright.quarantineIfUnreferenced(token: qTok, layout: layout) == .referenced && fm.fileExists(atPath: qDir.path))
        try fm.removeItem(at: fx.configFile)
        check("19.9 no mcp.json at all: provably unreferenced, quarantined",
              ManagedPlaywright.quarantineIfUnreferenced(token: qTok, layout: layout) == .quarantined && !fm.fileExists(atPath: qDir.path))
        for name in layout.leftovers().corrupt { try fm.removeItem(at: layout.mcpRoot.appendingPathComponent(name)) }

        // MARK: 20. Repaired same-token install reloads the registry (Codex round 2 additional)

        try writeConfig(["mcpServers": ["playwright": managedEntry(token: hA)]])
        try fm.removeItem(at: layout.versionDirectory(token: hA))
        _ = await MCPRegistry.shared.allToolDefinitions()
        let failedFirst = await MCPRegistry.shared.status().first { $0.name == "playwright" }?.failed
        let repaired20 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mA, flag: flag, reload: true))
        let status20 = await MCPRegistry.shared.status().first { $0.name == "playwright" }
        check("20.1 entry names a token whose directory is missing, registry already failed it: rebuilt under the same token, registry reloaded, server connected",
              failedFirst == true && repaired20 == .configured(token: hA, changed: true) && status20?.connected == true && status20?.failed == false,
              "\(repaired20) first=\(String(describing: failedFirst)) status=\(String(describing: status20))")
        await MCPRegistry.shared.shutdownAll()

        // MARK: 21. Profile import runs its read-modify-write under the config lock

        try writeConfig(["mcpServers": ["other": ["command": "uvx", "args": ["x"]]]])
        let seam21 = SeamState()
        MCPRegistry.testHookInsideMerge = {
            let thread = Thread {
                _ = try? MCPAgentRouting.withLockIfRoutingFile(fx.configFile.path) {
                    seam21.enteredLock = Date()
                    var root = (try? JSONSerialization.jsonObject(with: Data(contentsOf: fx.configFile)) as? [String: Any]) ?? [:]
                    var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
                    servers["seam2"] = ["command": "uvx", "args": ["seam2"]]
                    root["mcpServers"] = servers
                    try PrivateStorage.writeAtomically(try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), to: fx.configFile)
                }
                seam21.done = true
            }
            thread.start()
            Thread.sleep(forTimeInterval: 0.5)
            seam21.hookLeft = Date()
        }
        let bundle21 = try JSONSerialization.data(withJSONObject: [
            "version": ProfileBundle.currentVersion, "mcpServers": ["imp": ["command": "uvx", "args": ["imp"]]]])
        _ = try await ProfileBundle.importData(bundle21)
        MCPRegistry.testHookInsideMerge = nil
        for _ in 0..<100 where !seam21.done { try await Task.sleep(nanoseconds: 50_000_000) }
        let servers21 = (readConfigJSON()["mcpServers"] as? [String: Any]) ?? [:]
        check("21.1 file-tool edit during import: blocked until the import wrote, then applied on top — imp, seam2 and other all present",
              seam21.done && seam21.enteredLock != nil && seam21.hookLeft != nil && seam21.enteredLock! >= seam21.hookLeft!
              && servers21["imp"] != nil && servers21["seam2"] != nil && servers21["other"] != nil, "\(servers21.keys.sorted())")

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
                    guard let marker = entry()?["managed"] as? String, let token = ManagedPlaywright.token(fromMarker: marker) else { return false }
                    let text = try? String(contentsOf: caseLayout.versionDirectory(token: token).appendingPathComponent(ManagedPlaywright.completionMarkerName), encoding: .utf8)
                    return text?.trimmingCharacters(in: .whitespacesAndNewlines) == ManagedPlaywright.Layout.lockfileHash(ofToken: token)
                }
                let (crashStatus, crashOut) = runChild(crash: point)
                let isLegacy = (entry()?["command"] as? String) == "npx"
                let invariant = isLegacy || referencedDirValid()
                let stagingAfterCrash = caseLayout.leftovers().staging.count
                var parkedOK = true
                if point == .afterInstall {
                    // The interrupted staging is parked and the start refused;
                    // a human removes it, then the next start converges.
                    let (parkStatus, parkOut) = runChild(crash: nil)
                    parkedOK = parkStatus == 0 && parkOut.contains("OUTCOME: skipped") && parkOut.contains("interrupted install")
                        && caseLayout.leftovers().staging.isEmpty && caseLayout.leftovers().manual.count == 2
                    for name in caseLayout.leftovers().manual { try? fm.removeItem(at: caseLayout.mcpRoot.appendingPathComponent(name)) }
                }
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
                check("16.\(point.rawValue): crash exits 137, config never dangles (legacy or verified), \(point == .afterInstall ? "the interrupted staging is parked and refused, then after manual removal " : "")next start converges (npm runs \(expectedRuns), changed \(expectedChanged))",
                      crashStatus == 137 && invariant && status == 0 && converged && npmRuns == expectedRuns && changedOK && parkedOK
                      && (point != .afterInstall || stagingAfterCrash == 1),
                      "crash=\(crashStatus) legacy=\(isLegacy) valid=\(referencedDirValid()) staging=\(stagingAfterCrash) run=\(status) npm=\(npmRuns) out=\(out.suffix(200)) crashOut=\(crashOut.suffix(120))")
            }

            // MARK: 22. Crash DURING npm ci with a live descendant (Codex round 4)

            let caseRoot = tempRoot.appendingPathComponent("crash-during-npm", isDirectory: true)
            let caseConfigRoot = caseRoot.appendingPathComponent("briglia", isDirectory: true)
            try fm.createDirectory(at: caseConfigRoot, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["mcpServers": ["playwright": legacyEntry()]], options: [.sortedKeys])
                .write(to: caseConfigRoot.appendingPathComponent("mcp.json"))
            let caseLayout = ManagedPlaywright.Layout(dataRoot: caseConfigRoot)
            let caseLog = caseRoot.appendingPathComponent("npm-log.jsonl")
            let caseControl = caseRoot.appendingPathComponent("npm-control.json")
            let survivorPid = caseRoot.appendingPathComponent("survivor.pid")
            try JSONSerialization.data(withJSONObject: ["mode": "kill-parent-and-hang", "childPidFile": survivorPid.path,
                                                        "log": caseLog.path, "cliSource": fx.goodCli.path]).write(to: caseControl)
            let spec = caseRoot.appendingPathComponent("spec.json")
            try JSONSerialization.data(withJSONObject: [
                "manifestsDir": manifestsDir.path, "nodeDir": fx.nodeDir.path,
                "controlFile": caseControl.path, "flagFile": caseRoot.appendingPathComponent("flag").path,
            ]).write(to: spec)
            func runCase() -> (Int32, Bool, String) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: selfPath)
                p.arguments = ["__playwright-selftest", "--child-run", spec.path]
                var env = ProcessInfo.processInfo.environment
                env["XDG_CONFIG_HOME"] = caseRoot.path
                env["XDG_DATA_HOME"] = caseRoot.path
                env["TMPDIR"] = caseRoot.path + "/"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { return (-1, false, "\(error)") }
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                p.waitUntilExit()
                return (p.terminationStatus, p.terminationReason == .uncaughtSignal, out)
            }
            let (killedStatus, killedBySignal, _) = runCase()
            let survivor = Int32((try? String(contentsOf: survivorPid, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            let survivorAlive = survivor > 0 && kill(survivor, 0) == 0
            let stagingLeft = caseLayout.leftovers().staging
            check("22.1 parent killed while npm's descendant lives: the staging tree survives on disk, the descendant is still running",
                  killedBySignal && killedStatus == SIGKILL && stagingLeft.count == 1 && survivorAlive,
                  "status=\(killedStatus) signal=\(killedBySignal) staging=\(stagingLeft) survivor=\(survivor) alive=\(survivorAlive)")
            try JSONSerialization.data(withJSONObject: ["mode": "ok", "log": caseLog.path, "cliSource": fx.goodCli.path]).write(to: caseControl)
            let (restartStatus, _, restartOut) = runCase()
            let survivorStillAlive = survivor > 0 && kill(survivor, 0) == 0
            let manualAfter = caseLayout.leftovers().manual
            check("22.2 restart: the tree is parked (never deleted), the start refuses, the descendant is not signalled",
                  restartStatus == 0 && restartOut.contains("OUTCOME: skipped") && restartOut.contains("interrupted install")
                  && caseLayout.leftovers().staging.isEmpty && manualAfter.count == 2 && survivorStillAlive
                  && fm.fileExists(atPath: caseLayout.manualDirectory(stem: manualAfter.first { !$0.hasSuffix(".json") } ?? "?").appendingPathComponent("package.json").path),
                  "status=\(restartStatus) out=\(restartOut.suffix(300)) manual=\(manualAfter) alive=\(survivorStillAlive)")
            if survivor > 0 { kill(survivor, SIGKILL) }
            for name in caseLayout.leftovers().manual { try? fm.removeItem(at: caseLayout.mcpRoot.appendingPathComponent(name)) }
            let (healStatus, _, healOut) = runCase()
            check("22.3 after manual removal: the next start installs", healStatus == 0 && healOut.contains("OUTCOME: configured"), healOut.suffix(200).description)
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
        env["FAKE_NPM_PARENT_PID"] = String(getpid())
        env["PATH"] = nodeDir + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        deps.baseEnvironment = env
        deps.handshakeTimeout = 8
        deps.reloadRegistry = false
        deps.crashPoint = (spec["crashPoint"] as? String).flatMap(ManagedPlaywright.CrashPoint.init(rawValue:))
        deps.log = { print("log: \($0)") }
        let outcome = await BrowserAutomationBootstrap.ensureConfigured(dependencies: deps)
        switch outcome {
        case .configured(let token, let changed): print("OUTCOME: configured token: \(token) changed: \(changed)")
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
        let pkg = layout.versionDirectory(token: hash).appendingPathComponent(ManagedPlaywright.packageRelativePath)
        let installedVersion = (try? JSONSerialization.jsonObject(with: Data(contentsOf: pkg)) as? [String: Any])?["version"] as? String
        check("live.1 real npm ci against the committed lockfile + real handshake: configured in \(Int(Date().timeIntervalSince(t0)))s",
              outcome == .configured(token: hash, changed: true), "\(outcome)")
        check("live.2 installed @playwright/mcp is the pinned version", installedVersion == manifests.pinnedVersion, "\(installedVersion ?? "nil")")
        check("live.3 nothing group/other-readable under mcp/", PrivateStorage.sweep(apply: false).tightened == 0)
        let again = await BrowserAutomationBootstrap.ensureConfigured(dependencies: deps)
        check("live.4 second start reuses without npm", again == .configured(token: hash, changed: false), "\(again)")
    }

    final class SeamState: @unchecked Sendable {
        var enteredLock: Date?
        var hookLeft: Date?
        var done = false
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
    if mode == "kill-parent-and-hang":
        child = subprocess.Popen(["sleep", "600"])
        with open(ctl["childPidFile"], "w") as f:
            f.write(str(child.pid))
        os.kill(int(os.environ["FAKE_NPM_PARENT_PID"]), 9)
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
    import json, os, sys, time
    if os.environ.get("FAKE_MCP_PIDFILE"):
        with open(os.environ["FAKE_MCP_PIDFILE"], "w") as f:
            f.write(str(os.getpid()))
    delay = float(os.environ.get("FAKE_MCP_DELAY", "0"))
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
            if delay:
                time.sleep(delay)
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
