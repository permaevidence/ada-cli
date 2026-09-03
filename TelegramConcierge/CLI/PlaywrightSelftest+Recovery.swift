import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Second half of `__playwright-selftest` (sections 18–24: permanent parking,
/// quarantine windows, slow handshakes, chunked replies, same-token reload,
/// import under the config lock, crash injection). Split from
/// PlaywrightSelftest.swift because one async function of that size no
/// longer compiled inside an 8 GB Linux container; nothing checked changed.
extension PlaywrightSelftest {
    static func runBatteryRecovery(_ env: BatteryEnv) async throws {
        func check(_ label: String, _ ok: Bool, _ detail: String = "") { env.check(label, ok, detail) }
        let fm = FileManager.default
        let tempRoot = env.tempRoot
        let fx = env.fx
        let layout = env.layout
        let flag = env.flag
        let hA = env.hA, hC = env.hC
        let mA = env.mA, mC = env.mC
        let childPid = env.childPid
        func readConfigBytes() -> Data { env.readConfigBytes() }
        func readConfigJSON() -> [String: Any] { env.readConfigJSON() }
        func playwrightEntry() -> [String: Any]? { env.playwrightEntry() }
        func writeConfig(_ root: [String: Any]) throws { try env.writeConfig(root) }
        func legacyEntry(extra: [String: Any] = [:]) -> [String: Any] { env.legacyEntry(extra) }
        func managedEntry(token: String, extra: [String: Any] = [:]) -> [String: Any] { env.managedEntry(token, extra) }
        func markerText(_ token: String) -> String? { env.markerText(token) }
        func referencedToken() -> String? { env.referencedToken() }
        _ = (hA, hC, mA, mC, childPid, tempRoot, readConfigJSON, referencedToken)

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

        // MARK: 23. A slow handshake is not a verdict

        try writeConfig(["mcpServers": ["playwright": managedEntry(token: newE)]])
        try fm.removeItem(atPath: layout.cliPath(token: newE))
        try fm.copyItem(at: fx.slowCli, to: URL(fileURLWithPath: layout.cliPath(token: newE)))
        let bytes23 = readConfigBytes()
        let count23 = fx.npmInvocations().count
        let slow23 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        var slowOK = false
        if case .skipped(let r) = slow23, r.contains("could not verify") { slowOK = true }
        check("23.1 referenced tree whose handshake times out: skipped this start, tree kept, config byte-identical, no rebuild, no quarantine",
              slowOK && fm.fileExists(atPath: layout.versionDirectory(token: newE).path) && readConfigBytes() == bytes23
              && fx.npmInvocations().count == count23 && layout.leftovers().corrupt.isEmpty
              && ManagedPlaywright.readStatus(layout: layout)?.outcome == "skipped", "\(slow23)")
        // Unreferenced slow tree sorted first, a fast valid one after it: the
        // slow one is skipped (kept), the fast one chosen.
        try writeConfig(["mcpServers": ["playwright": legacyEntry()]])
        let fastE = hE + "-rfa570000"
        try fm.copyItem(at: layout.versionDirectory(token: newE), to: layout.versionDirectory(token: fastE))
        try fm.removeItem(atPath: layout.cliPath(token: fastE))
        try fm.copyItem(at: fx.goodCli, to: URL(fileURLWithPath: layout.cliPath(token: fastE)))
        let pick23 = await BrowserAutomationBootstrap.ensureConfigured(dependencies: fx.dependencies(manifests: mE, flag: flag))
        check("23.2 unreferenced slow tree before a fast valid one: skipped and kept, the fast one chosen and switched in, no npm",
              pick23 == .configured(token: fastE, changed: true) && fm.fileExists(atPath: layout.versionDirectory(token: newE).path)
              && layout.leftovers().corrupt.isEmpty && fx.npmInvocations().count == count23, "\(pick23)")
        // Restore the plain tree's fast server for the sections that follow.
        try fm.removeItem(atPath: layout.cliPath(token: newE))
        try fm.copyItem(at: fx.goodCli, to: URL(fileURLWithPath: layout.cliPath(token: newE)))
        try fm.removeItem(at: layout.versionDirectory(token: fastE))

        // MARK: 24. Large MCP replies must survive chunked pipe delivery

        // The real @playwright/mcp answers tools/list with ~30 KB; a reply
        // that spans several pipe reads must reassemble in order. A fake
        // server with a ~400 KB tool list, handshaken repeatedly.
        let bigCli = tempRoot.appendingPathComponent("big-cli.js")
        try ("import os\nos.environ['FAKE_MCP_BIG'] = '1'\n" + fakeServerSource).write(to: bigCli, atomically: true, encoding: .utf8)
        var bigFailures: [String] = []
        let bigStart = Date()
        for i in 0..<25 {
            let client = MCPClient(config: MCPServerConfig(name: "big", command: fx.nodeDir.appendingPathComponent("node").path, arguments: [bigCli.path]),
                                   resolvedEnvironment: fx.environment())
            do {
                try await client.start()
                try await client.initialize(timeout: 15)
                let tools = await client.listedTools
                if tools.count != 1500 { bigFailures.append("run \(i): \(tools.count) tools") }
            } catch {
                bigFailures.append("run \(i): \(error)")
            }
            await client.shutdown()
        }
        check("24.1 25 handshakes against a server whose tools/list is ~400 KB: every reply reassembled (1500 tools each), none lost to chunk reordering",
              bigFailures.isEmpty && Date().timeIntervalSince(bigStart) < 60, bigFailures.prefix(3).joined(separator: " | "))

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
}
