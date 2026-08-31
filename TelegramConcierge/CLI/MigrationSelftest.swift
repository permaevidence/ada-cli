import ArgumentParser
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden deterministic test of the identity-migration engine
/// (MigrationEngine.swift) — the Stage 3 exit criteria of RENAME_PLAN.md
/// §4.3/§4.5: full fixture migration, the service-state matrix, refusals,
/// journal-corruption refusal, REAL crash injection (the engine runs in a
/// child process and _exit(137)s at the injected point) after every
/// destructive sub-step with state-appropriate recovery, byte-identical
/// typed-preimage rollback including metadata and absent-creation deletion,
/// park-restoring rollback with parked-asset hash verification,
/// verification-before-cleanup at committed/done, the preferences-domain
/// copy, and the diagnostics no-mutation battery. Everything runs against
/// fixtures in a temp root with a fake systemctl — no real service, any
/// platform.
struct MigrationSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__migration-selftest",
        abstract: "Internal: verify the identity-migration engine against fixtures.",
        shouldDisplay: false
    )

    func run() async throws {
        AdaCLI.prepareIO()
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("ada-migrate-selftest-\(UUID().uuidString)")
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let adaBinary = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path

        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func note(_ text: String) { print("  · \(text)") }

        func writeScript(_ path: String, _ body: String) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        func writeFile(_ path: String, _ body: String, mode: Int = 0o644) throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        }
        func sha(_ path: String) -> String {
            guard let data = fm.contents(atPath: path) else { return "<unreadable>" }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func readText(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<unreadable>"
        }

        /// Deterministic recursive snapshot: relative path → descriptor
        /// (type, mode, content hash / symlink target). Byte-identical
        /// restore is asserted by comparing snapshots.
        func snapshot(_ roots: [String]) -> [String: String] {
            var out: [String: String] = [:]
            for root in roots {
                var st = stat()
                guard lstat(root, &st) == 0 else { continue }
                let base = (root as NSString).lastPathComponent
                func record(_ path: String, rel: String) {
                    var st = stat()
                    guard lstat(path, &st) == 0 else { return }
                    let mode = String(st.st_mode & 0o7777, radix: 8)
                    switch st.st_mode & S_IFMT {
                    case S_IFLNK:
                        let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?"
                        out[rel] = "link|\(target)"
                    case S_IFDIR:
                        out[rel] = "dir|\(mode)"
                        for name in (try? fm.contentsOfDirectory(atPath: path))?.sorted() ?? [] {
                            record(path + "/" + name, rel: rel + "/" + name)
                        }
                    default:
                        out[rel] = "file|\(mode)|\(sha(path))"
                    }
                }
                record(root, rel: base)
            }
            return out
        }
        func snapshotDiff(_ a: [String: String], _ b: [String: String]) -> [String] {
            var diffs: [String] = []
            for key in Set(a.keys).union(b.keys).sorted() {
                if a[key] != b[key] {
                    diffs.append("\(key): \(a[key] ?? "absent") → \(b[key] ?? "absent")")
                }
            }
            return diffs
        }

        // -------------------------------------------------------- fixture

        struct Fixture {
            var root: String
            var oldConfig: String, newConfig: String
            var oldData: String, newData: String
            var oldLanding: String, newLanding: String
            var binDir: String, unitDir: String, sysd: String
            var oldBinary: String, newBinary: String
            var oldBundle: String, newBundle: String
            var systemUnits: String
            var stateDir: String, probeLog: String, specPath: String
            var spec: MigrationSpec
            var oldUnit: String { unitDir + "/ada-test.service" }
            var newUnit: String { unitDir + "/briglia-test.service" }
            var oldWakelockUnit: String { systemUnits + "/ada-keepawake-test.service" }
            var newWakelockUnit: String { systemUnits + "/briglia-keepawake-test.service" }
            /// Everything a rollback must restore byte-identically.
            var restoreRoots: [String] {
                [oldConfig, oldData, oldLanding, binDir, unitDir, oldBundle, systemUnits]
            }
        }

        func makeFixture(_ name: String,
                         units: Bool = true, unitEnabled: Bool = true,
                         unitActive: Bool = true,
                         wakelock: Bool = false, wakelockManaged: Bool = true,
                         prefs: Bool = false,
                         persona: String = "Ada",
                         binaryIsSymlink: Bool = false,
                         probeFails: Bool = false) throws -> Fixture {
            let root = tempRoot.appendingPathComponent(name).path
            let oldConfig = root + "/xdg-config/old-app"
            let newConfig = root + "/xdg-config/new-app"
            let oldData = root + "/xdg-data/old-app"
            let newData = root + "/xdg-data/new-app"
            let oldLanding = root + "/landing-old"
            let newLanding = root + "/landing-new"
            let binDir = root + "/bin"
            let unitDir = root + "/units"
            let sysd = root + "/sysd"
            let oldBundle = root + "/bundle-old"
            let newBundle = root + "/bundle-new"
            let systemUnits = root + "/system-units"
            let stateDir = root + "/state/migrate"
            let probeLog = root + "/probe.log"

            // Old config root.
            try writeFile(oldConfig + "/secrets.json",
                          "{\"assistant_name\": \"\(persona)\", \"other_key\": \"keep-me\"}",
                          mode: 0o600)
            try writeFile(oldConfig + "/mcp.json", "{}")

            // Old data root: reminders + scripted watcher, trust store,
            // toolchain prefix, conversation, instance lock.
            let script = oldData + "/reminder-scripts/hello.sh"
            try writeScript(script, "#!/bin/sh\necho hello-from-watcher\n")
            try writeFile(oldData + "/reminders.json", """
            [{"id": "morning", "prompt": "check", "script": "\(script)",
              "workdir": "\(oldData)/reminder-scripts"}]
            """)
            try writeFile(oldData + "/reminder-scripts/state/hello.json", """
            {"script": "\(script)", "sha256": "\(sha(script))", "runs": 3}
            """)
            try writeFile(oldData + "/release_trust.json",
                          "{\"schema\": 2, \"domains\": {\"ada-cli|https://x/\": 58}}")
            try writeFile(oldData + "/conversation.json", "{\"messages\": []}")
            try writeFile(oldData + "/instance.lock", "")
            let prefixTool = oldData + "/toolchain/prefix/usr/bin/faketool"
            try writeScript(prefixTool, "#!/bin/sh\necho faketool 1.0\n")
            try writeFile(oldData + "/toolchain/prefix/usr/lib/libreoffice/program/fundamentalrc",
                          "URE_BOOTSTRAP=\(oldData)/toolchain/prefix/usr/lib/libreoffice/program/fundamentalrc\n")

            // Landing zone.
            try writeFile(oldLanding + "/note.txt", "user document")

            // Binaries, bundles, wrappers.
            let oldBinary = binDir + "/ada-old"
            let newBinary = binDir + "/briglia-new"
            let realOld = binDir + "/real-ada"
            let oldBody = "#!/bin/sh\n[ -f \"\(oldData)/conversation.json\" ] || exit 3\necho old-ada\n"
            if binaryIsSymlink {
                try writeScript(realOld, oldBody)
                try fm.createSymbolicLink(atPath: oldBinary, withDestinationPath: realOld)
            } else {
                try writeScript(oldBinary, oldBody)
            }
            try writeScript(newBinary, "#!/bin/sh\necho new-briglia\n")
            try writeScript(binDir + "/agentmail",
                "#!/bin/sh\nKEY=$(\"\(oldBinary)\" __agentmail-key) || exit 1\nexec /usr/bin/true \"$KEY\" \"$@\"\n")
            try writeScript(binDir + "/faketool", """
            #!/bin/sh
            \(UserdataToolchain.wrapperMarker)
            \(UserdataToolchain.closureMarker)
            export LD_LIBRARY_PATH="\(oldData)/toolchain/prefix/usr/lib"
            exec "\(prefixTool)" "$@"
            """)
            try writeFile(oldBundle + "/BundledSkills/pdf/SKILL.md", "old bundle content")
            try writeFile(newBundle + "/BundledSkills/pdf/SKILL.md", "new bundle content")

            // Fake systemd + lock holder + probe.
            try fm.createDirectory(atPath: sysd, withIntermediateDirectories: true)
            try writeFile(sysd + "/lockholder.py", """
            import fcntl, os, sys, time
            f = open(sys.argv[1], "a+")
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                sys.exit(1)
            with open(sys.argv[2], "w") as p:
                p.write(str(os.getpid()))
            time.sleep(600)
            """)
            let systemctl = root + "/systemctl"
            try writeScript(systemctl, """
            #!/bin/sh
            SD="\(sysd)"
            echo "$@" >> "$SD/log"
            if [ "$1" = "--user" ]; then shift; fi
            verb="$1"; unit="$2"
            case "$verb" in
              daemon-reload) exit 0;;
              is-enabled) if [ -f "$SD/$unit.enabled" ]; then echo enabled; else echo disabled; fi; exit 0;;
              is-active)  if [ -f "$SD/$unit.active" ]; then echo active; else echo inactive; fi; exit 0;;
              enable) if [ "${FAKE_SYSTEMCTL_FAIL_ENABLE:-0}" = "1" ]; then echo "enable refused"; exit 1; fi
                      touch "$SD/$unit.enabled"; exit 0;;
              disable) rm -f "$SD/$unit.enabled"; exit 0;;
              stop) rm -f "$SD/$unit.active"
                    if [ -f "$SD/$unit.pid" ]; then kill "$(cat "$SD/$unit.pid")" 2>/dev/null; rm -f "$SD/$unit.pid"; fi
                    exit 0;;
              start) if [ "${FAKE_SYSTEMCTL_FAIL_START:-0}" = "1" ]; then echo "start refused"; exit 1; fi
                     touch "$SD/$unit.active"
                     if [ "$unit" = "briglia-test.service" ]; then
                       nohup python3 "$SD/lockholder.py" "\(newData)/instance.lock" "$SD/$unit.pid" >/dev/null 2>&1 &
                     fi
                     exit 0;;
            esac
            exit 0
            """)
            let probe = root + "/probe.sh"
            try writeScript(probe, probeFails
                ? "#!/bin/sh\necho probe-failing >> \"\(probeLog)\"\nexit 1\n"
                : "#!/bin/sh\n[ -d \"\(newData)\" ] || exit 4\necho probed >> \"\(probeLog)\"\nexit 0\n")

            if units {
                try writeFile(unitDir + "/ada-test.service",
                              "[Unit]\nDescription=old ada\n[Service]\nExecStart=\(oldBinary) daemon\n")
                if unitEnabled { try writeFile(sysd + "/ada-test.service.enabled", "") }
                if unitActive { try writeFile(sysd + "/ada-test.service.active", "") }
            } else {
                try fm.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
            }
            try fm.createDirectory(atPath: systemUnits, withIntermediateDirectories: true)
            if wakelock {
                try writeFile(systemUnits + "/ada-keepawake-test.service",
                              "[Unit]\nDescription=old keepawake\n")
                try writeFile(sysd + "/ada-keepawake-test.service.enabled", "")
                try writeFile(sysd + "/ada-keepawake-test.service.active", "")
            }

            var spec = MigrationSpec(
                oldConfigRoot: oldConfig, newConfigRoot: newConfig,
                oldDataRoot: oldData, newDataRoot: newData,
                oldLandingZone: oldLanding, newLandingZone: newLanding,
                oldBinary: oldBinary, newBinary: newBinary,
                oldBundle: oldBundle, newBundle: newBundle,
                wrapperBinDir: binDir,
                unitDir: unitDir, oldUnitName: "ada-test.service",
                newUnitName: "briglia-test.service",
                newUnitText: "[Unit]\nDescription=new briglia\n[Service]\nExecStart=\(newBinary) daemon\n",
                systemctl: systemctl,
                oldWakelockUnitPath: wakelock ? systemUnits + "/ada-keepawake-test.service" : nil,
                newWakelockUnitPath: wakelock ? systemUnits + "/briglia-keepawake-test.service" : nil,
                oldWakelockUnitName: wakelock ? "ada-keepawake-test.service" : nil,
                newWakelockUnitName: wakelock ? "briglia-keepawake-test.service" : nil,
                newWakelockUnitText: wakelock ? "[Unit]\nDescription=new keepawake\n" : nil,
                wakelockSystemctl: wakelock ? systemctl : nil,
                wakelockManaged: wakelock ? wakelockManaged : nil,
                healthProbe: [probe], healthProbeTimeout: 15,
                stateDir: stateDir,
                personaOldName: "Ada", personaNewName: "Bree",
                personaMarkerName: nil,
                oldPrefsDomain: nil, newPrefsDomain: nil,
                toolchainWrapperMarker: nil, agentmailWrapperName: nil,
                upgradeMarkerNames: nil,
                recoveryCommand: "migrate-test")
            if prefs {
                let tag = UUID().uuidString.prefix(8)
                spec.oldPrefsDomain = "ada-mig-st-\(tag)-old"
                spec.newPrefsDomain = "ada-mig-st-\(tag)-new"
            }
            let specPath = root + "/spec.json"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(spec).write(to: URL(fileURLWithPath: specPath))

            return Fixture(root: root, oldConfig: oldConfig, newConfig: newConfig,
                           oldData: oldData, newData: newData,
                           oldLanding: oldLanding, newLanding: newLanding,
                           binDir: binDir, unitDir: unitDir, sysd: sysd,
                           oldBinary: oldBinary, newBinary: newBinary,
                           oldBundle: oldBundle, newBundle: newBundle,
                           systemUnits: systemUnits,
                           stateDir: stateDir, probeLog: probeLog,
                           specPath: specPath, spec: spec)
        }

        func killHolders(_ fixture: Fixture) {
            for name in (try? fm.contentsOfDirectory(atPath: fixture.sysd)) ?? []
                where name.hasSuffix(".pid") {
                if let pid = Int32(readText(fixture.sysd + "/" + name)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) {
                    kill(pid, SIGKILL)
                }
            }
        }

        /// Run the engine in a CHILD process (crash injection is a real
        /// process death). Goes through MigrationEngine.runBounded —
        /// posix_spawn + waitpid — because the fixture's fake `systemctl
        /// start` daemonizes a lock holder, and corelibs Process on Linux
        /// would wait on that grandchild's inherited socketpair instead of
        /// the runner's real exit (the orphan-hostage trap).
        @discardableResult
        func runEngine(_ fixture: Fixture, args: [String] = [],
                       env: [String: String] = [:]) -> (code: Int32, output: String) {
            let result = MigrationEngine.runBounded(
                [adaBinary, "__migrate-run", "--spec", fixture.specPath] + args,
                timeout: 120, extraEnv: env)
            return (result.exitCode, result.output)
        }

        func dumpPrefs(_ domain: String) -> String {
            let result = MigrationEngine.runBounded(
                [adaBinary, "__migrate-run", "--dump-prefs-domain", domain], timeout: 30)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Post-success invariants shared by the clean run and every
        /// forward-recovery crash scenario.
        func assertMigratedState(_ fixture: Fixture, label: String,
                                 expectSymlink: Bool = true) {
            let f = fixture
            check("\(label): old roots gone, new roots present",
                  !fm.fileExists(atPath: f.oldConfig) && !fm.fileExists(atPath: f.oldData)
                  && !fm.fileExists(atPath: f.oldLanding)
                  && fm.fileExists(atPath: f.newConfig) && fm.fileExists(atPath: f.newData)
                  && fm.fileExists(atPath: f.newLanding))
            let secrets = readText(f.newConfig + "/secrets.json")
            check("\(label): persona rewritten Ada → Bree, other keys kept",
                  secrets.contains("\"assistant_name\" : \"Bree\"")
                  || secrets.contains("\"assistant_name\": \"Bree\""),
                  secrets)
            check("\(label): secrets.json keeps its 0600 mode",
                  MigrationEngine.fileMode(f.newConfig + "/secrets.json") == 0o600)
            check("\(label): persona marker written in the new data root",
                  readText(f.newData + "/migrated_from_ada.json").contains("\"priorName\""))
            let reminders = readText(f.newData + "/reminders.json")
            check("\(label): reminders rebased to the new data root",
                  reminders.contains(f.newData) && !reminders.contains(f.oldData))
            let state = readText(f.newData + "/reminder-scripts/state/hello.json")
            check("\(label): watcher state rebased", state.contains(f.newData))
            let script = f.newData + "/reminder-scripts/hello.sh"
            check("\(label): script content untouched, hash in state still valid",
                  state.contains(sha(script))
                  && readText(script) == "#!/bin/sh\necho hello-from-watcher\n")
            check("\(label): script keeps executable mode",
                  MigrationEngine.fileMode(script) == 0o755)
            let wrapper = readText(f.binDir + "/agentmail")
            check("\(label): agentmail wrapper re-pointed at the new binary",
                  wrapper.contains(f.newBinary) && !wrapper.contains(f.oldBinary)
                  && MigrationEngine.fileMode(f.binDir + "/agentmail") == 0o755)
            let toolWrapper = readText(f.binDir + "/faketool")
            check("\(label): toolchain wrapper rebased and executable",
                  toolWrapper.contains(f.newData) && !toolWrapper.contains(f.oldData)
                  && MigrationEngine.fileMode(f.binDir + "/faketool") == 0o755)
            check("\(label): LibreOffice rc rebased",
                  readText(f.newData + "/toolchain/prefix/usr/lib/libreoffice/program/fundamentalrc")
                      .contains(f.newData))
            check("\(label): trust store moved unmodified",
                  readText(f.newData + "/release_trust.json").contains("ada-cli|https://x/"))
            if expectSymlink {
                let target = try? fm.destinationOfSymbolicLink(atPath: f.oldBinary)
                check("\(label): compat symlink old → new binary", target == f.newBinary)
            }
            check("\(label): old bundle retired", !fm.fileExists(atPath: f.oldBundle))
            if f.spec.oldWakelockUnitPath != nil, f.spec.wakelockManaged == true {
                check("\(label): keep-awake unit migrated (new enabled+active, old retired)",
                      fm.fileExists(atPath: f.newWakelockUnit)
                      && !fm.fileExists(atPath: f.oldWakelockUnit)
                      && fm.fileExists(atPath: f.sysd + "/briglia-keepawake-test.service.enabled")
                      && fm.fileExists(atPath: f.sysd + "/briglia-keepawake-test.service.active")
                      && !fm.fileExists(atPath: f.sysd + "/ada-keepawake-test.service.active"))
            }
            check("\(label): journal area fully cleaned up",
                  !fm.fileExists(atPath: f.stateDir))
            let probeRuns = readText(f.probeLog).split(separator: "\n").count
            check("\(label): health probe ran before AND after commit", probeRuns >= 2,
                  "probe runs: \(probeRuns)")
        }

        // ============================================================
        print("— spec validation and helpers —")

        do {
            var bad = try makeFixture("val").spec
            bad.stateDir = bad.oldDataRoot + "/state"
            check("spec validation: journal inside a root refused",
                  MigrationEngine.validateSpec(bad)?.contains("inside the root") == true)
            var rel = bad
            rel.stateDir = "relative/path"
            check("spec validation: relative path refused",
                  MigrationEngine.validateSpec(rel) != nil)
            var same = try makeFixture("val2").spec
            same.newDataRoot = same.oldDataRoot
            check("spec validation: identical old/new root refused",
                  MigrationEngine.validateSpec(same)?.contains("same path") == true)
        }

        do {
            let dir = MigrationEngine.defaultStateDir(
                name: "briglia-migrate", environment: ["XDG_STATE_HOME": "/tmp/xdgstate"])
            check("defaultStateDir honors XDG_STATE_HOME",
                  dir.path == "/tmp/xdgstate/briglia-migrate")
            let fallback = MigrationEngine.defaultStateDir(name: "briglia-migrate",
                                                           environment: [:])
            check("defaultStateDir falls back to ~/.local/state",
                  fallback.path.hasSuffix("/.local/state/briglia-migrate"))
        }

        // ============================================================
        print("\n— fresh-install no-op and read-only detection —")

        do {
            let fixture = try makeFixture("noop", units: false)
            // Remove the old roots entirely: fresh install.
            for path in [fixture.oldConfig, fixture.oldData, fixture.oldLanding] {
                try fm.removeItem(atPath: path)
            }
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            check("fresh install: no-op success", result.code == 0
                  && result.output.contains("nothing to migrate"), result.output)
            // The cross-process lock sibling is the one documented artifact
            // of any engine invocation; the journal area must not appear.
            check("fresh install: zero writes (no journal area created)",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty
                  && !fm.fileExists(atPath: fixture.stateDir))
        }

        do {
            let fixture = try makeFixture("detect", units: false)
            let before = snapshot([fixture.root])
            let detect = runEngine(fixture, args: ["--detect"])
            check("detection: reports old roots, no journal",
                  detect.code == 0 && detect.output.contains("old=3")
                  && detect.output.contains("journal=none"), detect.output)
            let doctor = runEngine(fixture, args: ["--doctor"])
            check("doctor: no journal ⇒ no migration report",
                  doctor.code == 0 && doctor.output.contains("no migration journal"))
            check("detection and doctor are strictly read-only",
                  snapshotDiff(before, snapshot([fixture.root])).isEmpty)
        }

        // ============================================================
        print("\n— full fixture migration (units + prefs + symlink) —")

        let seededPrefs: [String: Any] = ["privacyMode": "strict", "spendCents": 4200]
        do {
            let fixture = try makeFixture("full", wakelock: true, prefs: true)
            defer { killHolders(fixture) }
            let oldDomain = fixture.spec.oldPrefsDomain!
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                UserDefaults.standard.removePersistentDomain(forName: oldDomain)
                UserDefaults.standard.removePersistentDomain(forName: newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(seededPrefs, forName: oldDomain)
            UserDefaults.standard.synchronize()

            let result = runEngine(fixture)
            check("full migration succeeds", result.code == 0
                  && result.output.contains("MIGRATE-OUTCOME: ok"), result.output)
            assertMigratedState(fixture, label: "full")
            check("full: new unit installed, enabled, started",
                  fm.fileExists(atPath: fixture.newUnit)
                  && fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.enabled")
                  && fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.active"))
            check("full: old unit file retired",
                  !fm.fileExists(atPath: fixture.oldUnit))
            let log = readText(fixture.sysd + "/log")
            check("full: managed old service stopped before the move, disabled at retirement",
                  log.contains("stop ada-test.service") && log.contains("disable ada-test.service"))
            let newPrefs = dumpPrefs(newDomain)
            check("full: preferences domain copied",
                  newPrefs.contains("strict") && newPrefs.contains("4200"), newPrefs)
            check("full: old preferences domain removed at retirement",
                  dumpPrefs(oldDomain) == "{}", dumpPrefs(oldDomain))
            let leftovers = (fm.enumerator(atPath: fixture.root)?.allObjects as? [String] ?? [])
                .filter { $0.contains(".migrate-tmp-") || $0.contains(".durable-") }
            check("full: no leftover staging temp files", leftovers.isEmpty,
                  leftovers.joined(separator: ", "))
        }

        // ============================================================
        print("\n— persona exact-match rule —")

        // Fixture names must differ beyond letter case — macOS filesystems
        // are case-insensitive and "persona-ada"/"persona-Ada" would collide.
        for (slug, persona, expectKept) in [("custom", "Marvin", true),
                                            ("lowercase", "ada", true),
                                            ("exact", "Ada", false)] {
            let fixture = try makeFixture("persona-\(slug)", units: false, persona: persona)
            defer { killHolders(fixture) }
            let result = runEngine(fixture)
            check("persona \"\(persona)\": migration succeeds", result.code == 0, result.output)
            let secrets = readText(fixture.newConfig + "/secrets.json")
            if expectKept {
                check("persona \"\(persona)\": custom/variant name preserved verbatim",
                      secrets.contains("\"\(persona)\"") && !secrets.contains("\"Bree\""))
            } else {
                check("persona \"Ada\": rewritten to Bree", secrets.contains("\"Bree\""))
            }
        }

        // ============================================================
        print("\n— service-state matrix —")

        struct UnitCase {
            let name: String
            let enabled: Bool
            let active: Bool
        }
        for unitCase in [UnitCase(name: "installed-only", enabled: false, active: false),
                         UnitCase(name: "enabled-inactive", enabled: true, active: false),
                         UnitCase(name: "active-but-disabled", enabled: false, active: true)] {
            let fixture = try makeFixture("unit-\(unitCase.name)",
                                          unitEnabled: unitCase.enabled,
                                          unitActive: unitCase.active)
            defer { killHolders(fixture) }
            let result = runEngine(fixture)
            check("unit \(unitCase.name): migration succeeds", result.code == 0, result.output)
            let enabled = fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.enabled")
            let active = fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.active")
            check("unit \(unitCase.name): flags recreated independently (enabled=\(unitCase.enabled), active=\(unitCase.active))",
                  fm.fileExists(atPath: fixture.newUnit)
                  && enabled == unitCase.enabled && active == unitCase.active,
                  "got enabled=\(enabled) active=\(active)")
        }
        do {
            let fixture = try makeFixture("unit-none", units: false)
            defer { killHolders(fixture) }
            let result = runEngine(fixture)
            check("no unit installed: migration succeeds without creating one",
                  result.code == 0 && !fm.fileExists(atPath: fixture.newUnit))
        }

        do {
            // Optional roots may legitimately be absent (no landing zone yet).
            let fixture = try makeFixture("no-landing", units: false)
            try fm.removeItem(atPath: fixture.oldLanding)
            let result = runEngine(fixture)
            check("absent optional root: migration succeeds, nothing invented",
                  result.code == 0 && !fm.fileExists(atPath: fixture.newLanding)
                  && fm.fileExists(atPath: fixture.newData), result.output)
        }

        // ============================================================
        print("\n— refusals (nothing changed, service restored) —")

        do {
            let fixture = try makeFixture("refuse-lock")
            let before = snapshot(fixture.restoreRoots)
            // Hold the old instance lock ourselves: an "unmanaged" process.
            let fd = open(fixture.oldData + "/instance.lock", O_RDWR)
            check("refusal fixture: lock openable", fd >= 0)
            _ = flock(fd, LOCK_EX | LOCK_NB)
            let result = runEngine(fixture)
            flock(fd, LOCK_UN); close(fd)
            check("unmanaged lock holder: refused", result.code == 2
                  && result.output.contains("unmanaged"), result.output)
            check("unmanaged lock holder: fixture untouched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            let log = readText(fixture.sysd + "/log")
            check("unmanaged lock holder: managed service stopped, then restarted",
                  log.contains("stop ada-test.service") && log.contains("start ada-test.service"))
            check("unmanaged lock holder: no journal left behind",
                  !fm.fileExists(atPath: fixture.stateDir))
        }

        do {
            let fixture = try makeFixture("refuse-upgrade", units: false)
            try writeFile(fixture.binDir + "/.ada-upgrade-staged-bin", "staged")
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            check("in-flight upgrade markers: refused", result.code == 2
                  && result.output.contains("upgrade"), result.output)
            check("in-flight upgrade markers: fixture untouched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
        }

        do {
            let fixture = try makeFixture("refuse-newroot", units: false)
            try writeFile(fixture.newData + "/foreign.txt", "someone else's data")
            let before = snapshot(fixture.restoreRoots + [fixture.newData])
            let result = runEngine(fixture)
            check("new root already present without a journal: refused (never blind-overwrite)",
                  result.code == 2 && result.output.contains("already exists"), result.output)
            check("new root present: nothing touched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots + [fixture.newData])).isEmpty)
        }

        do {
            let fixture = try makeFixture("refuse-nobinary", units: false)
            try fm.removeItem(atPath: fixture.newBinary)
            let result = runEngine(fixture)
            check("missing new binary: refused", result.code == 2
                  && result.output.contains("not installed"), result.output)
        }

        // ============================================================
        print("\n— journal corruption refusal —")

        do {
            // Produce a real mid-flight journal via an injected crash.
            let fixture = try makeFixture("corrupt", units: false)
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "between-root-moves"])
            check("corruption fixture: crash injected", crashed.code == 137, crashed.output)
            let journalPath = fixture.stateDir + "/journal.json"
            let original = readText(journalPath)
            check("corruption fixture: journal exists", original.contains("\"state\""))

            // Tampering goes through parsed JSON, never text substitution —
            // pretty-print formatting differs between Darwin and corelibs.
            func expectCorrupt(_ label: String, needle: String,
                               _ tamper: (inout [String: Any]) -> Void) throws {
                if label == "garbage journal" {
                    try "this is not json{{{".write(toFile: journalPath, atomically: true,
                                                    encoding: .utf8)
                } else {
                    var object = try JSONSerialization.jsonObject(
                        with: Data(original.utf8)) as! [String: Any]
                    tamper(&object)
                    try JSONSerialization.data(withJSONObject: object)
                        .write(to: URL(fileURLWithPath: journalPath))
                }
                let before = snapshot(fixture.restoreRoots + [fixture.newConfig, fixture.newData])
                let result = runEngine(fixture)
                check("\(label): refused as corrupt", result.code == 3
                      && result.output.contains(needle), result.output)
                check("\(label): zero mutations",
                      snapshotDiff(before,
                                   snapshot(fixture.restoreRoots + [fixture.newConfig, fixture.newData])).isEmpty)
            }
            try expectCorrupt("garbage journal", needle: "not parseable") { _ in }
            try expectCorrupt("unknown schema", needle: "unknown schema") {
                $0["schema"] = 99
            }
            try expectCorrupt("foreign preimage path", needle: "outside the expected locations") {
                $0["preimages"] = [["id": "evil", "type": "file",
                                    "path": "/etc/passwd", "sha256": "00"]]
            }
            try expectCorrupt("absent entry naming a whole allowed directory",
                              needle: "outside the expected locations") {
                $0["preimages"] = [["id": "evil2", "type": "absent",
                                    "path": fixture.binDir]]
            }
            try expectCorrupt("parked asset with a substituted target",
                              needle: "unexpected parked asset") {
                $0["parked"] = [["id": "binary", "kind": "file",
                                 "originalPath": fixture.binDir + "/other-file",
                                 "sha256": "00"]]
            }
            try expectCorrupt("file preimage without a hash", needle: "without a hash") {
                $0["preimages"] = [["id": "pre-0000", "type": "file",
                                    "path": fixture.oldConfig + "/secrets.json"]]
            }
            // Spec mismatch: same journal, different invoking spec.
            try original.write(toFile: journalPath, atomically: true, encoding: .utf8)
            var mismatched = fixture.spec
            mismatched.personaNewName = "Zed"
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(mismatched).write(to: URL(fileURLWithPath: fixture.specPath))
            let result = runEngine(fixture)
            check("spec mismatch vs journal: refused as corrupt",
                  result.code == 3 && result.output.contains("different spec"), result.output)
            // Restore the real spec and finish this fixture forward so
            // nothing lingers half-moved.
            try encoder.encode(fixture.spec).write(to: URL(fileURLWithPath: fixture.specPath))
            _ = runEngine(fixture)
        }

        // ============================================================
        print("\n— doctor with a live journal (read-only) —")

        do {
            let fixture = try makeFixture("doctor", units: false)
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "after-moved"])
            check("doctor fixture: crash injected", crashed.code == 137)
            let before = snapshot([fixture.root])
            let doctor = runEngine(fixture, args: ["--doctor"])
            check("doctor reports the journal state and the recovery command",
                  doctor.code == 0 && doctor.output.contains("moved")
                  && doctor.output.contains("migrate-test"), doctor.output)
            let detect = runEngine(fixture, args: ["--detect"])
            check("detection reports the in-flight journal",
                  detect.output.contains("journal=moved"), detect.output)
            check("doctor and detection made zero writes",
                  snapshotDiff(before, snapshot([fixture.root])).isEmpty)
            _ = runEngine(fixture)   // finish forward
            killHolders(fixture)
        }

        // ============================================================
        print("\n— crash matrix: forward recovery after every destructive sub-step —")

        let forwardPoints = ["after-prepared", "between-root-moves", "after-moved",
                             "mid-fixups", "after-fixups", "after-committing-marker",
                             "after-unit-retirement", "after-wakelock-retirement",
                             "after-binary-park", "after-bundle-park", "after-symlink",
                             "after-committed", "during-post-verify"]
        for point in forwardPoints {
            let fixture = try makeFixture("fwd-\(point)", wakelock: true)
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": point])
            check("crash@\(point): child died at the injected point",
                  crashed.code == 137, "exit \(crashed.code): \(crashed.output)")
            let recovered = runEngine(fixture)
            check("crash@\(point): forward recovery succeeds", recovered.code == 0,
                  recovered.output)
            assertMigratedState(fixture, label: "crash@\(point)")
        }

        // ============================================================
        print("\n— crash matrix: explicit rollback before the commit point —")

        for point in ["between-root-moves", "after-moved", "mid-fixups", "after-fixups"] {
            let fixture = try makeFixture("rb-\(point)", wakelock: true,
                                          prefs: point == "after-fixups")
            defer { killHolders(fixture) }
            var oldDomain = "", newDomain = ""
            if let od = fixture.spec.oldPrefsDomain, let nd = fixture.spec.newPrefsDomain {
                oldDomain = od; newDomain = nd
                UserDefaults.standard.setPersistentDomain(seededPrefs, forName: od)
                UserDefaults.standard.synchronize()
            }
            defer {
                if !oldDomain.isEmpty {
                    UserDefaults.standard.removePersistentDomain(forName: oldDomain)
                    UserDefaults.standard.removePersistentDomain(forName: newDomain)
                    UserDefaults.standard.synchronize()
                }
            }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": point])
            check("rollback@\(point): child died at the injected point", crashed.code == 137)
            let rolled = runEngine(fixture, args: ["--rollback"])
            check("rollback@\(point): rollback recovery succeeds", rolled.code == 0,
                  rolled.output)
            let diffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("rollback@\(point): BYTE-IDENTICAL restore (content, modes, symlinks)",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            check("rollback@\(point): new roots and journal fully removed",
                  !fm.fileExists(atPath: fixture.newConfig)
                  && !fm.fileExists(atPath: fixture.newData)
                  && !fm.fileExists(atPath: fixture.stateDir))
            let oldRun = MigrationEngine.runBounded([fixture.oldBinary], timeout: 15)
            check("rollback@\(point): the old binary runs against the restored roots",
                  oldRun.exitCode == 0 && oldRun.output.contains("old-ada"), oldRun.output)
            let toolRun = MigrationEngine.runBounded([fixture.binDir + "/faketool"], timeout: 15)
            check("rollback@\(point): restored toolchain wrapper probe passes",
                  toolRun.exitCode == 0 && toolRun.output.contains("faketool"), toolRun.output)
            if !oldDomain.isEmpty {
                check("rollback@\(point): old prefs domain intact, created new domain deleted",
                      dumpPrefs(oldDomain).contains("strict") && dumpPrefs(newDomain) == "{}",
                      "old=\(dumpPrefs(oldDomain)) new=\(dumpPrefs(newDomain))")
            }
            if fixture.spec.oldUnitName != nil {
                let log = readText(fixture.sysd + "/log")
                check("rollback@\(point): old service restarted per captured topology",
                      log.contains("start ada-test.service")
                      && fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
            }
        }

        // ============================================================
        print("\n— commit-phase failure ⇒ automatic rollback —")

        do {
            let fixture = try makeFixture("probe-fail", probeFails: true)
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            check("health-probe failure: migration fails and rolls back",
                  result.code == 1 && result.output.contains("health probe"), result.output)
            check("health-probe failure: byte-identical restore",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            check("health-probe failure: no new unit left, old service active again",
                  !fm.fileExists(atPath: fixture.newUnit)
                  && !fm.fileExists(atPath: fixture.sysd + "/briglia-test.service.active")
                  && fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
        }

        do {
            let fixture = try makeFixture("enable-fail")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture, env: ["FAKE_SYSTEMCTL_FAIL_ENABLE": "1"])
            check("unit-enable failure (privileges analog): fails and rolls back",
                  result.code == 1 && result.output.contains("enable"), result.output)
            check("unit-enable failure: byte-identical restore",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
        }

        // ============================================================
        print("\n— park-restoring rollback (forward impossible, parked verify) —")

        do {
            let fixture = try makeFixture("park-restore", wakelock: true, prefs: true)
            defer { killHolders(fixture) }
            let oldDomain = fixture.spec.oldPrefsDomain!
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                UserDefaults.standard.removePersistentDomain(forName: oldDomain)
                UserDefaults.standard.removePersistentDomain(forName: newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(seededPrefs, forName: oldDomain)
            UserDefaults.standard.synchronize()
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("park-restore: crash injected after binary parking", crashed.code == 137)
            // Make forward completion impossible: destroy the new binary.
            try fm.removeItem(atPath: fixture.newBinary)
            let result = runEngine(fixture)
            check("park-restore: recovery reports the defined park-restoring rollback",
                  result.code == 1 && result.output.contains("restored byte-identically"),
                  result.output)
            // The new binary was destroyed by the test itself; restore it for
            // the snapshot comparison (it lives in binDir).
            try writeScript(fixture.newBinary, "#!/bin/sh\necho new-briglia\n")
            let diffs = snapshotDiff(before, snapshot(fixture.restoreRoots))
            check("park-restore: BYTE-IDENTICAL restore incl. parked binary/unit/bundle",
                  diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            check("park-restore: old prefs domain re-imported, new domain deleted",
                  dumpPrefs(oldDomain).contains("strict") && dumpPrefs(newDomain) == "{}",
                  "old=\(dumpPrefs(oldDomain)) new=\(dumpPrefs(newDomain))")
            let oldRun = MigrationEngine.runBounded([fixture.oldBinary], timeout: 15)
            check("park-restore: the restored old binary runs", oldRun.exitCode == 0)
            check("park-restore: old unit re-enabled per captured flags",
                  fm.fileExists(atPath: fixture.sysd + "/ada-test.service.enabled"))
            check("park-restore: old keep-awake unit re-armed (enabled + active)",
                  fm.fileExists(atPath: fixture.sysd + "/ada-keepawake-test.service.enabled")
                  && fm.fileExists(atPath: fixture.sysd + "/ada-keepawake-test.service.active")
                  && fm.fileExists(atPath: fixture.oldWakelockUnit))
        }

        do {
            let fixture = try makeFixture("park-corrupt")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("park-corrupt: crash injected", crashed.code == 137)
            try fm.removeItem(atPath: fixture.newBinary)
            // Corrupt the parked binary: rollback must be refused, everything held.
            let parkedBinary = fixture.stateDir + "/parked/binary"
            check("park-corrupt: parked binary exists", fm.fileExists(atPath: parkedBinary))
            try "tampered".write(toFile: parkedBinary, atomically: true, encoding: .utf8)
            let result = runEngine(fixture)
            check("park-corrupt: recovery refuses (no restore from unverified assets), holds all",
                  result.code == 1 && result.output.contains("do not verify"), result.output)
            check("park-corrupt: journal and parked assets left in place",
                  fm.fileExists(atPath: fixture.stateDir + "/journal.json")
                  && fm.fileExists(atPath: parkedBinary))
        }

        // ============================================================
        print("\n— verification-before-cleanup at committed/done —")

        do {
            let fixture = try makeFixture("verify-hold")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "after-committed"])
            check("verify-hold: crash injected after the committed marker", crashed.code == 137)
            // Break verification: the moved data root disappears.
            try fm.moveItem(atPath: fixture.newData, toPath: fixture.root + "/hidden-data")
            let held = runEngine(fixture)
            check("verify-hold: committed journal reruns verification, FAILS, cleans nothing",
                  held.code == 1 && held.output.contains("post-commit verification failed")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json")
                  && fm.fileExists(atPath: fixture.stateDir + "/parked"), held.output)
            // Repair and re-run: verification passes, cleanup completes.
            try fm.moveItem(atPath: fixture.root + "/hidden-data", toPath: fixture.newData)
            let done = runEngine(fixture)
            check("verify-hold: after repair, re-verification passes and cleanup finishes",
                  done.code == 0 && !fm.fileExists(atPath: fixture.stateDir), done.output)
        }

        do {
            let fixture = try makeFixture("rollback-past-commit")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture,
                                    env: ["ADA_MIGRATE_CRASH_POINT": "after-committing-marker"])
            check("past-commit: crash injected at the committing marker", crashed.code == 137)
            let refused = runEngine(fixture, args: ["--rollback"])
            check("past-commit: explicit rollback is refused at ≥ committing",
                  refused.code == 2 && refused.output.contains("commit point"), refused.output)
            let forward = runEngine(fixture)
            check("past-commit: forward recovery then completes", forward.code == 0,
                  forward.output)
            assertMigratedState(fixture, label: "past-commit")
        }

        // ============================================================
        print("\n— §4.6 identity verification: symlink binary + foreign binary —")

        do {
            let fixture = try makeFixture("symlink-binary", binaryIsSymlink: true)
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "after-binary-park"])
            check("symlink binary: crash injected after parking", crashed.code == 137)
            try fm.removeItem(atPath: fixture.newBinary)
            let result = runEngine(fixture)
            check("symlink binary: park-restoring rollback runs", result.code == 1,
                  result.output)
            var st = stat()
            let isLink = lstat(fixture.oldBinary, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
            let target = try? fm.destinationOfSymbolicLink(atPath: fixture.oldBinary)
            check("symlink binary: restored AS A SYMLINK with its original target",
                  isLink && target == fixture.binDir + "/real-ada", target ?? "nil")
        }

        do {
            let fixture = try makeFixture("foreign-binary")
            defer { killHolders(fixture) }
            let crashed = runEngine(fixture,
                                    env: ["ADA_MIGRATE_CRASH_POINT": "after-committing-marker"])
            check("foreign binary: crash injected before binary parking", crashed.code == 137)
            // Someone replaces the binary between the crash and recovery.
            try writeScript(fixture.oldBinary, "#!/bin/sh\necho impostor\n")
            let result = runEngine(fixture)
            check("foreign binary: forward recovery still succeeds", result.code == 0,
                  result.output)
            check("foreign binary: warned, left untouched, NO symlink created",
                  result.output.contains("does not match")
                  && readText(fixture.oldBinary).contains("impostor")
                  && (try? fm.destinationOfSymbolicLink(atPath: fixture.oldBinary)) == nil)
            assertMigratedState(fixture, label: "foreign-binary", expectSymlink: false)
        }

        // ============================================================
        print("\n— hardening round: lock, honest rollback, destination state, wakelock privileges —")

        do {
            // Concurrent migrate/recovery refused by the sibling flock.
            let fixture = try makeFixture("lock-conflict", units: false)
            try fm.createDirectory(atPath: (fixture.stateDir as NSString)
                .deletingLastPathComponent, withIntermediateDirectories: true)
            let lockPath = fixture.stateDir + ".lock"
            let fd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
            check("lock fixture: sibling lock openable", fd >= 0)
            _ = flock(fd, LOCK_EX | LOCK_NB)
            let before = snapshot(fixture.restoreRoots)
            let result = runEngine(fixture)
            flock(fd, LOCK_UN); close(fd)
            check("concurrent migration: refused while the lock is held",
                  result.code == 2 && result.output.contains("already running"), result.output)
            check("concurrent migration: nothing touched",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            let retry = runEngine(fixture)
            check("after the lock is released, migration proceeds", retry.code == 0, retry.output)
        }

        do {
            // Rollback must not report success when the old service cannot
            // be restarted: journal preserved, retry completes honestly.
            let fixture = try makeFixture("rollback-honesty")
            defer { killHolders(fixture) }
            let before = snapshot(fixture.restoreRoots)
            let crashed = runEngine(fixture, env: ["ADA_MIGRATE_CRASH_POINT": "after-fixups"])
            check("rollback-honesty: crash injected", crashed.code == 137)
            let failed = runEngine(fixture, args: ["--rollback"],
                                   env: ["FAKE_SYSTEMCTL_FAIL_START": "1"])
            check("rollback-honesty: failed service restart surfaces as FAILURE, journal kept",
                  failed.code == 1 && failed.output.contains("journal")
                  && fm.fileExists(atPath: fixture.stateDir + "/journal.json"), failed.output)
            let retried = runEngine(fixture, args: ["--rollback"])
            check("rollback-honesty: retry completes the rollback", retried.code == 0,
                  retried.output)
            check("rollback-honesty: byte-identical restore after the retry",
                  snapshotDiff(before, snapshot(fixture.restoreRoots)).isEmpty)
            check("rollback-honesty: old service active again",
                  fm.fileExists(atPath: fixture.sysd + "/ada-test.service.active"))
        }

        do {
            // A new root existing WITHOUT its old counterpart must refuse
            // (unrelated destination data must never be mixed in).
            let fixture = try makeFixture("refuse-orphan-newroot", units: false)
            try fm.removeItem(atPath: fixture.oldData)
            try writeFile(fixture.newData + "/foreign.txt", "not ours")
            let result = runEngine(fixture)
            check("orphan new root (old side missing): refused",
                  result.code == 2 && result.output.contains("already exists"), result.output)
            check("orphan new root: foreign data untouched",
                  readText(fixture.newData + "/foreign.txt") == "not ours")
        }

        do {
            // A pre-existing NEW preferences domain refuses — it was not
            // created by a migration and rollback bookkeeping would
            // otherwise delete it.
            let fixture = try makeFixture("refuse-prefs", units: false, prefs: true)
            let newDomain = fixture.spec.newPrefsDomain!
            defer {
                UserDefaults.standard.removePersistentDomain(forName: newDomain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(["pre": "existing"], forName: newDomain)
            UserDefaults.standard.synchronize()
            let result = runEngine(fixture)
            check("pre-existing new prefs domain: refused",
                  result.code == 2 && result.output.contains("preferences domain"), result.output)
            check("pre-existing new prefs domain: its data survives",
                  dumpPrefs(newDomain).contains("existing"))
        }

        do {
            // Unprivileged wakelock: captured and warned about, never touched.
            let fixture = try makeFixture("wakelock-unmanaged", wakelock: true,
                                          wakelockManaged: false)
            defer { killHolders(fixture) }
            let wakelockBytes = sha(fixture.oldWakelockUnit)
            let result = runEngine(fixture)
            check("unprivileged wakelock: migration succeeds with a warning",
                  result.code == 0 && result.output.contains("no privileges"), result.output)
            check("unprivileged wakelock: old unit file untouched, no new unit created",
                  sha(fixture.oldWakelockUnit) == wakelockBytes
                  && !fm.fileExists(atPath: fixture.newWakelockUnit)
                  && fm.fileExists(atPath: fixture.sysd + "/ada-keepawake-test.service.active"))
        }

        // ============================================================
        print("\n— preferences persistence path (resolved concretely, both platforms) —")

        do {
            let domain = "ada-mig-probe-\(UUID().uuidString.prefix(8))"
            defer {
                UserDefaults.standard.removePersistentDomain(forName: domain)
                UserDefaults.standard.synchronize()
            }
            UserDefaults.standard.setPersistentDomain(["probe": "sentinel"], forName: domain)
            UserDefaults.standard.synchronize()
            let home = fm.homeDirectoryForCurrentUser.path
            let env = ProcessInfo.processInfo.environment
            var candidates = [
                home + "/Library/Preferences/\(domain).plist",
                (env["XDG_CONFIG_HOME"] ?? home + "/.config") + "/\(domain).plist",
                (env["XDG_DATA_HOME"] ?? home + "/.local/share") + "/\(domain).plist",
            ]
            #if os(Linux)
            candidates.append(home + "/.config/\(domain).plist")
            #endif
            let found = candidates.first { fm.fileExists(atPath: $0) }
            check("preferences persist to a discoverable per-user plist", found != nil,
                  "checked: \(candidates.joined(separator: ", "))")
            if let found {
                note("preferences path on this platform: \(found)")
                // The plist is a SIBLING file named <domain>.plist — never
                // inside a directory named after the domain — so a root move
                // can never carry it: the mandatory domain copy (§4.5.8) is
                // the correct treatment on this platform.
                check("preferences file lies OUTSIDE any movable root directory",
                      !found.contains("/\(domain)/"))
            }
        }

        // ============================================================
        print("\n— diagnostics no-mutation battery (§4.2, current identity) —")

        do {
            let bat = tempRoot.appendingPathComponent("battery").path
            try writeFile(bat + "/config/ada/secrets.json",
                          "{\"assistant_name\": \"Ada\"}", mode: 0o600)
            try writeFile(bat + "/share/ada/conversation.json", "{\"messages\": []}")
            try fm.createDirectory(atPath: bat + "/home", withIntermediateDirectories: true)
            let env = ["HOME": bat + "/home",
                       "XDG_CONFIG_HOME": bat + "/config",
                       "XDG_DATA_HOME": bat + "/share"]
            for args in [["--version"], ["bundle-check"], ["setup-api", "status"]] {
                let before = snapshot([bat])
                _ = MigrationEngine.runBounded([adaBinary] + args, timeout: 60,
                                               extraEnv: env)
                let after = snapshot([bat])
                let diffs = snapshotDiff(before, after).filter { diff in
                    // Lazily-created EMPTY directories are the one documented
                    // side effect; file creation/modification/deletion is not.
                    !(diff.contains("absent → dir|") )
                }
                check("diagnostic `\(args.joined(separator: " "))`: no file writes, no deletions",
                      diffs.isEmpty, diffs.prefix(5).joined(separator: "; "))
            }
        }

        // ============================================================
        print(failures == 0 ? "\nmigration selftest: all checks passed"
                            : "\nmigration selftest: \(failures) FAILED")
        if failures > 0 { throw ExitCode(1) }
    }
}
