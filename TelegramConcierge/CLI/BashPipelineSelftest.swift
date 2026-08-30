import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Hidden diagnostic: exercises the streaming bash output pipeline against
/// the failure modes it was built for — pipe-buffer back-pressure, orphaned
/// pipe writers, UTF-8 sequences and secrets split across chunk boundaries,
/// spill-file integrity, and timeout behavior. Run by the smoke suite on
/// both platforms; exits nonzero on any failure.
struct BashPipelineSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__bash-pipeline-selftest",
        abstract: "Internal: verify the streaming bash output pipeline.",
        shouldDisplay: false
    )

    func run() async throws {
        // Line-buffer stdout: when the harness pipes us and later has to
        // SIGKILL a hang, block-buffered output would vanish and the hang
        // location with it.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Isolated XDG roots: pipeline runs execute real registry jobs and
        // must not write field-observation stats into a real installation.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-bash-pipeline-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        // Watchdog: a hang on a slow CI runner must die HERE with a marker,
        // not as a mute harness-level subprocess timeout.
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 240_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: selftest exceeded 240s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, detail: String = "") {
            print("  \(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        func payload(_ result: BashTools.OpResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
        }

        // MARK: 1. Incremental UTF-8 decoder units
        print("UTF-8 decoder")
        do {
            var d = IncrementalUTF8Decoder()
            // "è" = 0xC3 0xA8 split across chunks.
            let a = d.decode(Data([0x61, 0xC3]))
            let b = d.decode(Data([0xA8, 0x62]))
            check("2-byte split", a == "a" && b == "èb", detail: "got '\(a)'+'\(b)'")

            var d3 = IncrementalUTF8Decoder()
            // "€" = 0xE2 0x82 0xAC split 1+2.
            let e1 = d3.decode(Data([0xE2]))
            let e2 = d3.decode(Data([0x82, 0xAC]))
            check("3-byte split", e1 == "" && e2 == "€", detail: "got '\(e1)'+'\(e2)'")

            var d4 = IncrementalUTF8Decoder()
            // "🐕" = F0 9F 90 95 split 2+2.
            let f1 = d4.decode(Data([0xF0, 0x9F]))
            let f2 = d4.decode(Data([0x90, 0x95]))
            check("4-byte split", f1 == "" && f2 == "🐕", detail: "got '\(f1)'+'\(f2)'")

            var dInvalid = IncrementalUTF8Decoder()
            // Lone continuation byte: lossy replacement, not chunk loss.
            let g = dInvalid.decode(Data([0x61, 0x80, 0x62]))
            check("invalid byte is lossy, not dropped", g.contains("a") && g.contains("b"), detail: "got '\(g)'")

            var dFlush = IncrementalUTF8Decoder()
            _ = dFlush.decode(Data([0xE2]))
            let h = dFlush.flush()
            check("flush mid-character yields replacement", !h.isEmpty, detail: "got empty")
        }

        // MARK: 2. Streaming redactor units
        print("Streaming redactor")
        do {
            let secret = "SECRET_ABCDEFGH_1234567"
            let r = StreamingRedactor(environment: ["TEST_KEY": secret])
            var out = r.process("prefix " + String(secret.prefix(9)))
            out += r.process(String(secret.dropFirst(9)) + " suffix")
            out += r.flush()
            check("secret split across chunks",
                  out == "prefix [REDACTED:TEST_KEY] suffix" && !out.contains(secret),
                  detail: "got '\(out)'")

            let r2 = StreamingRedactor(environment: ["TEST_KEY": secret])
            var out2 = ""
            for ch in secret { out2 += r2.process(String(ch)) }   // one char per chunk
            out2 += r2.flush()
            check("secret split char-by-char", out2 == "[REDACTED:TEST_KEY]", detail: "got '\(out2)'")

            let r3 = StreamingRedactor(environment: ["A": "AAAA1111", "B": "BB22"])
            var out3 = r3.process("xxAAAA1111BB")
            out3 += r3.process("22yy")
            out3 += r3.flush()
            check("adjacent secrets, second split",
                  out3 == "xx[REDACTED:A][REDACTED:B]yy", detail: "got '\(out3)'")

            let r4 = StreamingRedactor(environment: [:])
            check("no-secret passthrough", r4.process("hello") == "hello")
        }

        // MARK: 3. Collector spill with a secret straddling the spill boundary
        print("Collector spill")
        do {
            let secret = "SECRET_ABCDEFGH_1234567"
            let collector = ForegroundStreamCollector(streamLabel: "selftest", secrets: ["TEST_KEY": secret])
            // Push past the 50KB spill threshold, then a split secret.
            let filler = String(repeating: "x", count: 60_000)
            collector.ingest(Data(filler.utf8))
            collector.ingest(Data(("AB " + String(secret.prefix(11))).utf8))
            collector.ingest(Data((String(secret.dropFirst(11)) + " CD\n").utf8))
            let final = collector.finalize()
            let spillOK: Bool
            var spillDetail = "no spill path"
            if let path = final.spillPath, let content = try? String(contentsOfFile: path, encoding: .utf8) {
                let perms = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
                spillOK = !content.contains(secret)
                    && content.contains("[REDACTED:TEST_KEY]")
                    && content.hasPrefix("xxxxx")
                    && perms == 0o600
                spillDetail = "rawLeak=\(content.contains(secret)) perms=\(perms.map { String($0, radix: 8) } ?? "nil")"
                try? FileManager.default.removeItem(atPath: path)
            } else {
                spillOK = false
            }
            check("spill file redacted + mode 600", spillOK, detail: spillDetail)
            check("preview references spill", final.truncated && final.text.contains("Full output"),
                  detail: String(final.text.prefix(80)))
        }

        do {
            // Codex review finding: a failed FIRST spill write used to fall
            // through and overwrite the rescued tail with the emptied
            // buffer, losing all output. Inject the write fault and assert
            // the tail survives.
            setenv("ADA_TEST_SPILL_FAULT", "write", 1)
            let collector = ForegroundStreamCollector(streamLabel: "faulttest", secrets: [:])
            collector.ingest(Data(String(repeating: "y", count: 60_000).utf8))
            collector.ingest(Data("TAIL_MARKER_XYZ\n".utf8))
            let final = collector.finalize()
            unsetenv("ADA_TEST_SPILL_FAULT")
            check("spill write fault keeps the rescued tail",
                  final.spillPath == nil && final.truncated
                  && final.text.contains("TAIL_MARKER_XYZ") && final.text.contains("yyyy"),
                  detail: "spillPath=\(final.spillPath ?? "nil") truncated=\(final.truncated) len=\(final.text.count)")
        }

        // MARK: 4. Foreground: large output must not deadlock or truncate the spill
        print("Foreground pipeline")
        do {
            let t0 = Date()
            let result = await BashTools.runAttached(command: "seq 1 200000")
            let wall = Date().timeIntervalSince(t0)
            let p = payload(result)
            let spillPath = p["stdout_full_output_path"] as? String
            var lineCount = -1
            if let spillPath, let content = try? String(contentsOfFile: spillPath, encoding: .utf8) {
                lineCount = content.split(separator: "\n", omittingEmptySubsequences: true).count
            }
            check("1.4MB output: success without timeout",
                  p["success"] as? Bool == true && p["execution_timed_out"] as? Bool == false && wall < 60,
                  detail: "success=\(p["success"] ?? "?") execution_timed_out=\(p["execution_timed_out"] ?? "?") wall=\(Int(wall))s")
            check("1.4MB output: complete spill (200000 lines)", lineCount == 200_000,
                  detail: "got \(lineCount), path=\(spillPath ?? "nil")")
            check("1.4MB output: truncated flag + tail preview",
                  p["stdout_truncated"] as? Bool == true
                  && (p["stdout"] as? String)?.contains("200000") == true,
                  detail: "tail misses last line")
            if let spillPath { try? FileManager.default.removeItem(atPath: spillPath) }
        }

        do {
            // Single line larger than the pipe buffer — no line boundaries to lean on.
            let result = await BashTools.runAttached(
                command: "awk 'BEGIN{for(i=0;i<300000;i++)printf \"a\"; print \"\"}'")
            let p = payload(result)
            let spillPath = p["stdout_full_output_path"] as? String
            var bytes = -1
            if let spillPath,
               let attrs = try? FileManager.default.attributesOfItem(atPath: spillPath),
               let size = attrs[.size] as? Int { bytes = size }
            check("300KB single line: success + complete spill",
                  p["success"] as? Bool == true && bytes == 300_001,
                  detail: "success=\(p["success"] ?? "?") spillBytes=\(bytes)")
            if let spillPath { try? FileManager.default.removeItem(atPath: spillPath) }
        }

        do {
            // Multibyte output large enough that kernel chunking splits characters.
            let result = await BashTools.runAttached(
                command: "awk 'BEGIN{for(i=0;i<50000;i++)printf \"\\303\\250\"}'")
            let p = payload(result)
            let spillPath = p["stdout_full_output_path"] as? String
            var ok = false
            var detail = "no spill"
            if let spillPath, let content = try? String(contentsOfFile: spillPath, encoding: .utf8) {
                ok = !content.contains("\u{FFFD}") && content.utf8.count == 100_000 && content.count == 50_000
                detail = "bytes=\(content.utf8.count) chars=\(content.count) fffd=\(content.contains("\u{FFFD}"))"
                try? FileManager.default.removeItem(atPath: spillPath)
            }
            check("100KB of 2-byte chars: no split-char corruption", ok, detail: detail)
        }

        do {
            // Orphan holding the pipe: the old readToEnd blocked until the
            // orphan exited (15s here); post-exit grace must return fast.
            let t0 = Date()
            let result = await BashTools.runAttached(command: "sleep 15 & echo started")
            let wall = Date().timeIntervalSince(t0)
            let p = payload(result)
            check("orphan pipe writer: fast return with output",
                  p["success"] as? Bool == true
                  && (p["stdout"] as? String)?.contains("started") == true
                  && wall < 6,
                  detail: "wall=\(String(format: "%.1f", wall))s exit=\(p["exit_code"] ?? "?") stdout='\((p["stdout"] as? String ?? "").prefix(40))'")
        }

        do {
            let t0 = Date()
            let result = await BashTools.runAttached(command: "sleep 20", killAfterSeconds: 2)
            let wall = Date().timeIntervalSince(t0)
            let p = payload(result)
            check("timeout still enforced",
                  p["execution_timed_out"] as? Bool == true && p["success"] as? Bool == false && wall < 10,
                  detail: "execution_timed_out=\(p["execution_timed_out"] ?? "?") wall=\(Int(wall))s")
        }

        do {
            // /proc/<pid>/stat parsing, unit-level on BOTH platforms: field
            // 52 (exit_code) is the last field and carries the trailing
            // newline — the untrimmed Int32 parse returned nil and silently
            // degraded every Linux zombie exit code to -1.
            func statLine(state: String, exitField: String) -> String {
                let fields = [state] + Array(repeating: "0", count: 48) + [exitField]
                return "123 (co mm) " + fields.joined(separator: " ")
            }
            let clean = BashTools.parseProcStatZombie(statLine(state: "Z", exitField: "0\n"))
            let exit3 = BashTools.parseProcStatZombie(statLine(state: "Z", exitField: "768\n"))
            let killed = BashTools.parseProcStatZombie(statLine(state: "Z", exitField: "9\n"))
            let alive = BashTools.parseProcStatZombie(statLine(state: "S", exitField: "0\n"))
            check("proc stat zombie parse survives trailing newline",
                  clean == (true, 0) && exit3 == (true, 3)
                  && killed == (true, 137) && alive.isZombie == false,
                  detail: "clean=\(String(describing: clean)) exit3=\(String(describing: exit3)) killed=\(String(describing: killed))")
        }

        do {
            // success must reflect the exit code, not just "didn't time out".
            let result = await BashTools.runAttached(command: "echo out; exit 3")
            let p = payload(result)
            check("nonzero exit reports success=false with exit_code",
                  p["success"] as? Bool == false
                  && p["exit_code"] as? Int == 3
                  && p["execution_timed_out"] as? Bool == false,
                  detail: "success=\(p["success"] ?? "?") exit=\(p["exit_code"] ?? "?")")
        }

        // MARK: 5. Background reader: split multibyte chars must survive
        print("Background pipeline")
        do {
            let start = await BashTools.runBackground(
                command: "awk 'BEGIN{for(i=0;i<50000;i++)printf \"\\303\\250\"}'")
            let sp = payload(start)
            if let handle = sp["handle"] as? String {
                var snapshot: BackgroundProcessRegistry.Snapshot?
                for _ in 0..<150 {  // up to 15s
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    snapshot = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)
                    if let s = snapshot, s.status != .running { break }
                }
                let out = snapshot?.stdout ?? ""
                check("background 100KB of 2-byte chars: no corruption",
                      snapshot?.status == .exited && !out.contains("\u{FFFD}") && out.utf8.count == 100_000,
                      detail: "status=\(snapshot?.status.rawValue ?? "nil") bytes=\(out.utf8.count) fffd=\(out.contains("\u{FFFD}"))")
            } else {
                check("background 100KB of 2-byte chars: no corruption", false,
                      detail: "spawn failed: \(start.content.prefix(120))")
            }
        }

        // MARK: 6. Process-tree termination
        print("Process tree")
        func pgrepMatches(_ pattern: String) -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["pgrep", "-f", pattern]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return -1 }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline).count
        }

        do {
            // The trampoline's COMMON path on Foundation spawns is the
            // posix_spawn SETSID fallback: the shim stays as the tracked pid
            // and the real shell runs as its child in a NEW session. Verify
            // that shape explicitly, then verify termination reaps both.
            let start = await BashTools.runBackground(command: "sleep 3111")
            let sp = payload(start)
            if let handle = sp["handle"] as? String, let shimPid = sp["pid"] as? Int {
                try? await Task.sleep(nanoseconds: 500_000_000)  // let the shim spawn its child
                let kids = ProcessTree.descendants(of: Int32(shimPid))
                let fallbackShape: Bool
                var detail = "kids=\(kids)"
                if let child = kids.first {
                    let shimSid = getsid(Int32(shimPid))
                    let childSid = getsid(child)
                    fallbackShape = childSid != shimSid && childSid == getpgid(child)
                    detail += " shimSid=\(shimSid) childSid=\(childSid) childPgid=\(getpgid(child))"
                } else {
                    // In-place setsid()+execv happy path: tracked pid IS the
                    // session leader. Not the common path under Foundation —
                    // flag it loudly so a platform behavior change is noticed.
                    fallbackShape = false
                }
                check("trampoline fallback: child in its own session", fallbackShape, detail: detail)
                _ = await BashTools.kill(handle: handle)
                try? await Task.sleep(nanoseconds: 800_000_000)
                check("kill reaps shim and detached child", pgrepMatches("sleep 3111") == 0,
                      detail: "survivors=\(pgrepMatches("sleep 3111"))")
            } else {
                check("trampoline fallback: child in its own session", false,
                      detail: "spawn failed: \(start.content.prefix(120))")
            }
        }

        // Sleep durations double as pgrep markers. Derive them from our pid
        // so a stale orphan leaked by a FAILED earlier run (which, being
        // TERM-immune, survives a default pkill) can never contaminate this
        // run's counts.
        let nonce = String(format: "%03d", ProcessInfo.processInfo.processIdentifier % 1000)
        func pkill9(_ pattern: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["pkill", "-9", "-f", pattern]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }

        do {
            // Double fork: `(sleep 47NNN &)` — the subshell exits instantly,
            // so by kill time the sleep has reparented to init and the
            // pgrep -P walk cannot see it. It KEEPS the shell's process
            // group, so only group signalling reaps it (via the trampoline's
            // group forwarding on TERM, or ProcessTree's group sweep).
            let m1 = "sleep 47\(nonce)"
            let m2 = "sleep 48\(nonce)"
            let result = await BashTools.runAttached(
                command: "(\(m1) &); \(m2)", killAfterSeconds: 2)
            let p = payload(result)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let orphans = pgrepMatches(m1)
            let foreground = pgrepMatches(m2)
            check("timeout group-kill reaps double-forked orphan",
                  p["execution_timed_out"] as? Bool == true && orphans == 0 && foreground == 0,
                  detail: "execution_timed_out=\(p["execution_timed_out"] ?? "?") orphans=\(orphans) fg=\(foreground)")
            pkill9(m1); pkill9(m2)
        }

        do {
            // Same double fork, but the orphan ignores SIGTERM (and its
            // sleep child inherits the ignored disposition across exec). The
            // trampoline can forward TERM to the child's group but can never
            // forward KILL (uncatchable) — only ProcessTree's group-SIGKILL
            // sweep reaps this one. Isolates the layer the plain double-fork
            // test can't (the two layers are deliberately redundant for TERM).
            let m1 = "sleep 59\(nonce)"
            let result = await BashTools.runAttached(
                command: "(sh -c 'trap \"\" TERM; \(m1)' &); sleep 60\(nonce)", killAfterSeconds: 2)
            let p = payload(result)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let orphans = pgrepMatches(m1)
            check("group-SIGKILL sweep reaps TERM-immune orphan",
                  p["execution_timed_out"] as? Bool == true && orphans == 0,
                  detail: "execution_timed_out=\(p["execution_timed_out"] ?? "?") orphans=\(orphans)")
            pkill9(m1); pkill9("sleep 60\(nonce)")
        }

        do {
            // Two orphans spewing on stdout AND stderr forever: neither
            // reader ever goes idle, so each rides its 5s hard cap. The
            // caps must run in PARALLEL — sequential finish() used to start
            // stderr's clock only after stdout's reader gave up (~10s).
            let marker = "grace\(nonce)"
            let t0 = Date()
            let result = await BashTools.runAttached(
                command: "( while :; do echo \(marker); echo \(marker) >&2; sleep 0.03; done & ); echo hi",
                killAfterSeconds: 30)
            let wall = Date().timeIntervalSince(t0)
            let p = payload(result)
            check("spewing dual-stream orphan: grace caps run in parallel",
                  p["success"] as? Bool == true
                  && (p["stdout"] as? String)?.contains("hi") == true
                  && wall < 8,
                  detail: "wall=\(String(format: "%.1f", wall))s exit=\(p["exit_code"] ?? "?")")
            pkill9(marker)
        }

        // MARK: 7. Background termination path
        print("Background termination")
        func awaitBackgroundExit(_ handle: String, seconds: Double) async -> BackgroundProcessRegistry.Snapshot? {
            var snapshot: BackgroundProcessRegistry.Snapshot?
            for _ in 0..<Int(seconds * 10) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                snapshot = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)
                if let s = snapshot, s.status != .running { return s }
            }
            return snapshot
        }

        do {
            // Background command leaving a SILENT orphan holding the pipe
            // write end. The old termination handler stalled on a blocking
            // availableData residual drain (both platforms) and, on Linux,
            // corelibs' socketpair exit detection waited out the orphan's
            // lifetime — the completion notice arrived only when the orphan
            // died. The monitor + grace must deliver it within ~1s.
            let m = "sleep 49\(nonce)"
            let t0 = Date()
            let start = await BashTools.runBackground(command: "(\(m) &); echo bgdone")
            let sp = payload(start)
            if let handle = sp["handle"] as? String {
                let snapshot = await awaitBackgroundExit(handle, seconds: 8)
                let wall = Date().timeIntervalSince(t0)
                check("background orphan: completion within grace, not orphan lifetime",
                      snapshot?.status == .exited
                      && snapshot?.stdout.contains("bgdone") == true
                      && wall < 4,
                      detail: "status=\(snapshot?.status.rawValue ?? "nil") wall=\(String(format: "%.1f", wall))s")
            } else {
                check("background orphan: completion within grace, not orphan lifetime", false,
                      detail: "spawn failed: \(start.content.prefix(120))")
            }
            pkill9(m)
        }

        do {
            // 300KB burst immediately before exit: the poll-readers must
            // capture the full tail (Linux readabilityHandler dropped the
            // final pipe buffer; the old single availableData could recover
            // at most ~64KB of it). Rolling cap keeps the last 120KB, so
            // the end marker and a large retained tail must both survive.
            let start = await BashTools.runBackground(
                command: "awk 'BEGIN{for(i=0;i<3000;i++)printf \"%0100d\\n\",i; print \"ENDMARK\(nonce)\"}'")
            let sp = payload(start)
            if let handle = sp["handle"] as? String {
                let snapshot = await awaitBackgroundExit(handle, seconds: 10)
                let out = snapshot?.stdout ?? ""
                check("background 300KB burst: tail complete through poll-readers",
                      snapshot?.status == .exited
                      && out.contains("ENDMARK\(nonce)")
                      && out.utf8.count >= 100_000,
                      detail: "status=\(snapshot?.status.rawValue ?? "nil") bytes=\(out.utf8.count) endmark=\(out.contains("ENDMARK\(nonce)"))")

                // Cumulative offset contract: total_bytes must span the
                // EVICTED output (~303KB produced vs ~120KB buffered) — the
                // old buffer-relative accounting reported ≤120KB and made
                // incremental reads lie after eviction. Reading from 0 must
                // flag the gap; reading from total must return nothing new.
                let o1 = payload(await BashTools.output(handle: handle))
                let total = o1["stdout_total_bytes"] as? Int ?? -1
                check("cumulative offsets: total spans evicted output + gap flagged",
                      total > 250_000 && o1["stdout_gap"] as? Bool == true,
                      detail: "total=\(total) gap=\(o1["stdout_gap"] ?? "nil")")
                let o2 = payload(await BashTools.output(handle: handle, since: total, sinceStderr: 0))
                check("cumulative offsets: since=total returns empty, no gap",
                      (o2["stdout"] as? String)?.isEmpty == true
                      && o2["stdout_gap"] == nil,
                      detail: "len=\((o2["stdout"] as? String)?.utf8.count ?? -1) gap=\(o2["stdout_gap"] ?? "nil")")

                // The COMPLETE stream must be on disk: everything past the
                // 120KB rolling cap used to be simply gone. Mode 600, full
                // byte count, first line AND end marker present.
                let spillPath = o1["stdout_full_output_path"] as? String
                var spillOK = false
                var spillDetail = "no stdout_full_output_path in payload"
                if let path = spillPath,
                   let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                    let mode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? -1
                    spillOK = contents.utf8.count >= 300_000
                        && contents.hasPrefix(String(format: "%0100d", 0))
                        && contents.contains("ENDMARK\(nonce)")
                        && mode == 0o600
                    spillDetail = "bytes=\(contents.utf8.count) mode=\(String(mode, radix: 8))"
                }
                check("background spill file: complete redacted stream on disk", spillOK,
                      detail: spillDetail)
            } else {
                check("background 300KB burst: tail complete through poll-readers", false,
                      detail: "spawn failed: \(start.content.prefix(120))")
            }
        }

        do {
            // Watches must keep firing now that chunks flow through the
            // poll-reader sinks instead of readabilityHandler.
            let token = "WOOF\(nonce)"
            let start = await BashTools.runBackground(command: "sleep 0.3; echo \(token); sleep 0.3")
            let sp = payload(start)
            if let handle = sp["handle"] as? String {
                let reg = await BackgroundProcessRegistry.shared.registerWatch(handle: handle, pattern: token, limit: 1)
                var matched = false
                if case .success = reg {
                    for _ in 0..<60 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        let events = await BackgroundProcessRegistry.shared.drainWatchMatches()
                        if events.contains(where: { $0.line.contains(token) }) { matched = true; break }
                    }
                }
                check("watch fires through poll-reader sink", matched,
                      detail: "registered=\((try? reg.get()) != nil ? "yes" : "no")")
            } else {
                check("watch fires through poll-reader sink", false,
                      detail: "spawn failed: \(start.content.prefix(120))")
            }
        }

        if failures > 0 {
            print("\n\(failures) bash pipeline check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll bash pipeline checks passed")
    }
}
