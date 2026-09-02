import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Phase 0 of the Managed Bash Jobs v2 redesign:
/// freeze the CURRENT model-visible bash payload contract before any
/// lifecycle refactor. Every check pins the exact JSON a tool result
/// carries today — full key set, sorted key order, static values —
/// with only genuinely volatile fields (pids, durations, spill paths,
/// signal-dependent exit codes) masked. Phase 1 must keep every one of
/// these goldens green while rerouting execution through the managed
/// registry; any drift in a key name, key presence, or static value is
/// a compatibility break, not a cosmetic change.
struct BashGoldenSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__bash-golden-selftest",
        abstract: "Internal: golden-payload compatibility tests for the bash tool surface.",
        shouldDisplay: false
    )

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Isolated XDG roots: golden runs execute real registry jobs and
        // must not write field-observation stats into a real installation.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-bash-golden-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 200_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: golden selftest exceeded 200s — hung; aborting")
                Foundation.exit(3)
            }
        }
        defer { watchdog.cancel() }

        var failures = 0
        func check(_ label: String, _ ok: Bool, detail: String = "") {
            print("  \(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        /// Serialize an expected payload with the SAME options production
        /// uses (sortedKeys + withoutEscapingSlashes), so goldens compare
        /// canonical string to canonical string.
        func encode(_ dict: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(
                    withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: data, encoding: .utf8) else { return "ENCODE_FAIL" }
            return s
        }

        /// Canonicalize an actual payload: parse, mask volatile fields,
        /// re-serialize sorted, and substitute the concrete handle with <H>
        /// everywhere (including inside message strings that embed it).
        func canonical(_ json: String, mask: [String] = [], handle: String? = nil) -> String {
            guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return "PARSE_FAIL: " + json
            }
            for key in mask where obj[key] != nil { obj[key] = "<masked>" }
            var s = encode(obj)
            if let handle { s = s.replacingOccurrences(of: handle, with: "<H>") }
            return s
        }

        /// Golden comparison: expected dict already contains "<masked>" /
        /// "<H>" placeholders. Prints both canonical strings on mismatch so
        /// the drift is directly diffable.
        func golden(_ label: String, _ actual: String, _ expected: [String: Any],
                    mask: [String] = [], handle: String? = nil) {
            let a = canonical(actual, mask: mask, handle: handle)
            let e = encode(expected)
            if a == e {
                check(label, true)
            } else {
                check(label, false, detail: "\n    expected: \(e)\n    actual:   \(a)")
            }
        }

        func payload(_ result: BashTools.OpResult) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
        }

        func awaitBackgroundExit(_ handle: String, seconds: Double) async -> BackgroundProcessRegistry.Snapshot? {
            var snapshot: BackgroundProcessRegistry.Snapshot?
            for _ in 0..<Int(seconds * 10) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                snapshot = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)
                if let s = snapshot, s.status != .running { return s }
            }
            return snapshot
        }

        func removeSpill(_ result: BashTools.OpResult) {
            let p = payload(result)
            for key in ["stdout_full_output_path", "stderr_full_output_path"] {
                if let path = p[key] as? String { try? FileManager.default.removeItem(atPath: path) }
            }
        }

        // MARK: 1. Attached-execution goldens (foreground-only subagents, internal scripts)
        print("Attached payload goldens")

        func section1() async throws {
            // Byte-for-byte literal, no canonicalization: pins the exact
            // encoder behavior (sorted keys, unescaped slashes, bool
            // rendering). Everything in this payload is deterministic.
            let result = await BashTools.runAttached(command: "printf /a/b")
            let expected = #"{"cancelled_by_user":false,"command":"printf /a/b","description":"","execution_timed_out":false,"exit_code":0,"kill_after_seconds":120,"stderr":"","stderr_truncated":false,"stdout":"/a/b","stdout_truncated":false,"success":true}"#
            check("attached literal: exact bytes incl. unescaped slashes", result.content == expected,
                  detail: "\n    expected: \(expected)\n    actual:   \(result.content)")
        }
        try await section1()

        func section2() async throws {
            let cmd = "printf out; printf err >&2"
            let result = await BashTools.runAttached(command: cmd, description: "golden")
            golden("attached success: full payload", result.content, [
                "cancelled_by_user": false, "command": cmd, "description": "golden",
                "execution_timed_out": false, "exit_code": 0,
                "kill_after_seconds": 120,
                "stderr": "err", "stderr_truncated": false,
                "stdout": "out", "stdout_truncated": false,
                "success": true
            ])
        }
        try await section2()

        func section3() async throws {
            let cmd = "printf partial; exit 7"
            let result = await BashTools.runAttached(command: cmd)
            golden("attached nonzero exit: success=false, exit_code kept", result.content, [
                "cancelled_by_user": false, "command": cmd, "description": "",
                "execution_timed_out": false, "exit_code": 7,
                "kill_after_seconds": 120,
                "stderr": "", "stderr_truncated": false,
                "stdout": "partial", "stdout_truncated": false,
                "success": false
            ])
        }
        try await section3()

        func section4() async throws {
            let result = await BashTools.runAttached(command: "printf y", killAfterSeconds: 9999)
            golden("attached deadline clamp: ceiling 600s echoed", result.content, [
                "cancelled_by_user": false, "command": "printf y", "description": "",
                "execution_timed_out": false, "exit_code": 0,
                "kill_after_seconds": 600,
                "stderr": "", "stderr_truncated": false,
                "stdout": "y", "stdout_truncated": false,
                "success": true
            ])
        }
        try await section4()

        func section5() async throws {
            // exit_code after a deadline kill is signal-derived and differs
            // by platform — masked. Everything else is contractual.
            let cmd = "printf pre; sleep 20"
            let result = await BashTools.runAttached(command: cmd, killAfterSeconds: 2)
            golden("attached deadline: execution_timed_out=true, partial output kept", result.content, [
                "cancelled_by_user": false, "command": cmd, "description": "",
                "execution_timed_out": true, "exit_code": "<masked>",
                "kill_after_seconds": 2,
                "stderr": "", "stderr_truncated": false,
                "stdout": "pre", "stdout_truncated": false,
                "success": false
            ], mask: ["exit_code"])
        }
        try await section5()

        func section6() async throws {
            let cmd = "printf c; sleep 30"
            let task = Task { await BashTools.runAttached(command: cmd) }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            task.cancel()
            let result = await task.value
            golden("attached cancellation: cancelled_by_user=true, not timed out", result.content, [
                "cancelled_by_user": true, "command": cmd, "description": "",
                "execution_timed_out": false, "exit_code": "<masked>",
                "kill_after_seconds": 120,
                "stderr": "", "stderr_truncated": false,
                "stdout": "c", "stdout_truncated": false,
                "success": false
            ], mask: ["exit_code"])
        }
        try await section6()

        func section7() async throws {
            // Attached stdin is the null device: a `read` sees EOF at
            // once and fails with rc=1 on both zsh and bash — the child
            // must never share (or block on) Briglia's terminal.
            let result = await BashTools.runAttached(command: "read x; echo rc=$?")
            golden("attached stdin: null device, read fails immediately", result.content, [
                "cancelled_by_user": false, "command": "read x; echo rc=$?", "description": "",
                "execution_timed_out": false, "exit_code": 0,
                "kill_after_seconds": 120,
                "stderr": "", "stderr_truncated": false,
                "stdout": "rc=1\n", "stdout_truncated": false,
                "success": true
            ])
        }
        try await section7()

        func section8() async throws {
            let result = await BashTools.runAttached(
                command: "true", workdir: "/nonexistent/ada-golden-selftest")
            golden("attached workdir error: exact error payload", result.content, [
                "error": "workdir does not exist: /nonexistent/ada-golden-selftest"
            ])
        }
        try await section8()

        func section9() async throws {
            let result = await BashTools.runAttached(
                command: "true", serviceKeyEnv: ["GOLDEN_ENV": "golden-no-such-label"])
            golden("attached service_key_env unknown label: exact error payload", result.content, [
                "error": "service_key_env: unknown keys: golden-no-such-label"
            ])
        }
        try await section9()

        func section10() async throws {
            // Spill contract: past the inline threshold the payload gains
            // stdout_full_output_path and flips stdout_truncated. Content
            // and path are masked; the KEY SET is the golden.
            let cmd = #"awk 'BEGIN{for(i=0;i<600;i++)printf "%0100d",i; print ""}'"#
            let result = await BashTools.runAttached(command: cmd)
            golden("attached spill: key set with stdout_full_output_path", result.content, [
                "cancelled_by_user": false, "command": cmd, "description": "",
                "execution_timed_out": false, "exit_code": 0,
                "kill_after_seconds": 120,
                "stdout": "<masked>", "stdout_full_output_path": "<masked>",
                "stdout_truncated": true,
                "stderr": "", "stderr_truncated": false,
                "success": true
            ], mask: ["stdout", "stdout_full_output_path"])
            removeSpill(result)
        }
        try await section10()

        // MARK: 1b. Managed default-policy goldens (§3.1 lifecycle matrix)
        print("Managed default-policy goldens")

        func section11() async throws {
            // A settled default quick command: the managed snapshot payload
            // with the default wait/kill policy echoed.
            let result = await BashTools.runManaged(
                command: "printf mdef", requestedWaitSeconds: 120,
                effectiveWaitSeconds: 120, waitRefusalReason: nil,
                killAfterSeconds: 120)
            golden("managed default settle: full payload key set", result.content, [
                "command": "printf mdef", "description": "",
                "effective_wait_seconds": 120, "exit_code": 0,
                "handle": "<H>", "kill_after_seconds": 120,
                "pid": "<masked>", "running_for_seconds": "<masked>",
                "status": "exited",
                "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                "stdout": "mdef", "stdout_total_bytes": 4, "stdout_truncated": false,
                "success": true, "waited_seconds": "<masked>"
            ], mask: ["pid", "running_for_seconds", "waited_seconds"],
               handle: (payload(result)["handle"] as? String))
            _ = await BackgroundProcessRegistry.shared.drainCompletions()
        }
        try await section11()

        func section12() async throws {
            // The §6.2.5 contract: equal wait and kill deadlines yield ONE
            // terminal execution_timed_out snapshot in the same call — never
            // a running handle followed by a mislabeled completion.
            let cmd = "printf pre; sleep 30"
            let result = await BashTools.runManaged(
                command: cmd, requestedWaitSeconds: 2,
                effectiveWaitSeconds: 2, waitRefusalReason: nil,
                killAfterSeconds: 2)
            golden("managed default deadline: atomic terminal timed_out snapshot", result.content, [
                "command": cmd, "description": "",
                "effective_wait_seconds": 2, "execution_timed_out": true,
                "exit_code": "<masked>",
                "handle": "<H>", "kill_after_seconds": 2,
                "pid": "<masked>", "running_for_seconds": "<masked>",
                "status": "timed_out",
                "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                "stdout": "pre", "stdout_total_bytes": 3, "stdout_truncated": false,
                "success": true, "waited_seconds": "<masked>"
            ], mask: ["exit_code", "pid", "running_for_seconds", "waited_seconds"],
               handle: (payload(result)["handle"] as? String))
            check("managed default deadline: receipt minted (result observed in-call)",
                  result.receipt != nil)
            _ = await BackgroundProcessRegistry.shared.drainCompletions()
        }
        try await section12()

        // MARK: 2. Background lifecycle goldens (start → output → input → exit → completion)
        print("Background lifecycle goldens")

        let bgCmd = "printf bgout; read line; printf bgdone"
        var bgHandle: String?
        func section13() async throws {
            // wait_seconds=0 is the model-visible detach path: the managed
            // snapshot payload plus the usage message.
            let start = await BashTools.runManaged(
                command: bgCmd, requestedWaitSeconds: 0,
                effectiveWaitSeconds: 0, waitRefusalReason: nil,
                killAfterSeconds: nil, description: "bg golden")
            let sp = payload(start)
            bgHandle = sp["handle"] as? String
            golden("bg start (wait=0): full payload incl. usage message", start.content, [
                "command": bgCmd, "description": "bg golden",
                "effective_wait_seconds": 0, "handle": "<H>",
                "message": "Process started. Use bash_manage (mode 'output'/'input'/'watch'/'wait'/'kill') with this handle. You will be notified automatically when it exits.",
                "pid": "<masked>", "running_for_seconds": "<masked>",
                "status": "running",
                "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                "stdout": "<masked>", "stdout_total_bytes": "<masked>", "stdout_truncated": false,
                "success": true, "waited_seconds": 0
            ], mask: ["pid", "running_for_seconds", "stdout", "stdout_total_bytes"], handle: bgHandle)
            check("bg start: handle format bash_N",
                  bgHandle?.hasPrefix("bash_") == true, detail: bgHandle ?? "nil")
        }
        try await section13()

        if let handle = bgHandle {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            do {
                let result = await BashTools.output(handle: handle)
                golden("bg output while running: full payload, NO exit_code key", result.content, [
                    "command": bgCmd, "handle": "<H>", "running_for_seconds": "<masked>",
                    "status": "running",
                    "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                    "stdout": "bgout", "stdout_total_bytes": 5, "stdout_truncated": false,
                    "success": true
                ], mask: ["running_for_seconds"], handle: handle)
            }

            do {
                let result = await BashTools.input(handle: handle, text: "go", appendNewline: true)
                golden("bg input: full payload", result.content, [
                    "append_newline": true, "bytes_written": 3, "handle": "<H>",
                    "message": "Input written to background process stdin. Use bash_manage(mode='output') to inspect the response.",
                    "success": true
                ], handle: handle)
            }

            let snapshot = await awaitBackgroundExit(handle, seconds: 10)
            check("bg exits after stdin", snapshot?.status == .exited,
                  detail: "status=\(snapshot?.status.rawValue ?? "nil")")

            do {
                let result = await BashTools.output(handle: handle)
                golden("bg output after exit: exit_code present, status exited", result.content, [
                    "command": bgCmd, "exit_code": 0, "handle": "<H>",
                    "running_for_seconds": "<masked>", "status": "exited",
                    "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                    "stdout": "bgoutbgdone", "stdout_total_bytes": 11, "stdout_truncated": false,
                    "success": true
                ], mask: ["running_for_seconds"], handle: handle)
            }

            do {
                let result = await BashTools.input(handle: handle, text: "late", appendNewline: false)
                golden("bg input after exit: exact error payload", result.content, [
                    "error": "background process is not running: <H>"
                ], handle: handle)
            }

            do {
                // Completion struct contract, field by field. Duration is
                // volatile; every other field is pinned.
                let completions = await BackgroundProcessRegistry.shared.drainCompletions()
                let c = completions.first
                let fields = c.map {
                    "handle=\($0.handleId == handle ? "<H>" : $0.handleId) command=\($0.command) desc=\($0.description ?? "nil") exit=\($0.exitCode) status=\($0.status.rawValue) stdout=\($0.stdoutTail) stderr=\($0.stderrTail) spill=\($0.stdoutFullPath ?? "nil"),\($0.stderrFullPath ?? "nil")"
                } ?? "NO COMPLETION"
                let expected = "handle=<H> command=\(bgCmd) desc=bg golden exit=0 status=exited stdout=bgoutbgdone stderr= spill=nil,nil"
                check("bg completion: one event with pinned fields",
                      completions.count == 1 && fields == expected && (c?.durationSeconds ?? -1) >= 0,
                      detail: "count=\(completions.count)\n    expected: \(expected)\n    actual:   \(fields)")
                let again = await BackgroundProcessRegistry.shared.drainCompletions()
                check("bg completion: drain is destructive (second drain empty)", again.isEmpty,
                      detail: "count=\(again.count)")
            }
        } else {
            check("bg lifecycle goldens", false, detail: "background spawn failed")
        }

        // MARK: 3. Kill goldens
        print("Kill goldens")
        func section14() async throws {
            let start = await BashTools.runBackground(command: "sleep 300")
            if let handle = payload(start)["handle"] as? String {
                let result = await BashTools.kill(handle: handle)
                golden("kill: full payload", result.content, [
                    "handle": "<H>",
                    "message": "Sent SIGTERM (then SIGKILL if still running).",
                    "success": true
                ], handle: handle)

                let snapshot = await awaitBackgroundExit(handle, seconds: 8)
                check("kill: status becomes killed", snapshot?.status == .killed,
                      detail: "status=\(snapshot?.status.rawValue ?? "nil")")

                let out = await BashTools.output(handle: handle)
                golden("kill: output payload after kill (signal exit masked)", out.content, [
                    "command": "sleep 300", "exit_code": "<masked>", "handle": "<H>",
                    "running_for_seconds": "<masked>", "status": "killed",
                    "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                    "stdout": "", "stdout_total_bytes": 0, "stdout_truncated": false,
                    "success": true
                ], mask: ["exit_code", "running_for_seconds"], handle: handle)

                let again = await BashTools.kill(handle: handle)
                golden("kill twice: exact already-stopped error", again.content, [
                    "error": "unknown or already-stopped handle: <H>"
                ], handle: handle)

                let completions = await BackgroundProcessRegistry.shared.drainCompletions()
                check("kill: completion carries status killed",
                      completions.count == 1 && completions.first?.status == .killed,
                      detail: "count=\(completions.count) status=\(completions.first?.status.rawValue ?? "nil")")
            } else {
                check("kill goldens", false, detail: "background spawn failed")
            }
        }
        try await section14()

        // MARK: 4. Unknown-handle error goldens
        print("Unknown-handle goldens")
        func section15() async throws {
            golden("unknown handle output: exact error",
                   (await BashTools.output(handle: "bash_999999")).content,
                   ["error": "unknown background handle: bash_999999"])
            golden("unknown handle kill: exact error",
                   (await BashTools.kill(handle: "bash_999999")).content,
                   ["error": "unknown or already-stopped handle: bash_999999"])
            golden("unknown handle input: exact error",
                   (await BashTools.input(handle: "bash_999999", text: "x")).content,
                   ["error": "unknown background handle: bash_999999"])
        }
        try await section15()

        // MARK: 5. Eviction / cumulative-offset key goldens
        print("Eviction goldens")
        func section16() async throws {
            // 303,000 deterministic bytes: total_bytes is exact even though
            // the evicted split depends on chunk boundaries (masked).
            let cmd = #"awk 'BEGIN{for(i=0;i<3000;i++)printf "%0100d\n",i}'"#
            let start = await BashTools.runBackground(command: cmd)
            if let handle = payload(start)["handle"] as? String {
                let snapshot = await awaitBackgroundExit(handle, seconds: 15)
                check("eviction: burst job exits", snapshot?.status == .exited,
                      detail: "status=\(snapshot?.status.rawValue ?? "nil")")

                let o1 = await BashTools.output(handle: handle)
                golden("eviction: gap keys + exact cumulative total", o1.content, [
                    "command": cmd, "exit_code": 0, "handle": "<H>",
                    "running_for_seconds": "<masked>", "status": "exited",
                    "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                    "stdout": "<masked>", "stdout_evicted_bytes": "<masked>",
                    "stdout_full_output_path": "<masked>", "stdout_gap": true,
                    "stdout_total_bytes": 303_000, "stdout_truncated": true,
                    "success": true
                ], mask: ["running_for_seconds", "stdout", "stdout_evicted_bytes",
                          "stdout_full_output_path"], handle: handle)

                let o2 = await BashTools.output(handle: handle, since: 303_000, sinceStderr: 0)
                golden("eviction: since=total drops gap keys, empty stdout", o2.content, [
                    "command": cmd, "exit_code": 0, "handle": "<H>",
                    "running_for_seconds": "<masked>", "status": "exited",
                    "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                    "stdout": "", "stdout_full_output_path": "<masked>",
                    "stdout_total_bytes": 303_000, "stdout_truncated": false,
                    "success": true
                ], mask: ["running_for_seconds", "stdout_full_output_path"], handle: handle)

                removeSpill(o1)
                _ = await BackgroundProcessRegistry.shared.drainCompletions()
            } else {
                check("eviction goldens", false, detail: "background spawn failed")
            }
        }
        try await section16()

        // MARK: 6. Watch contract goldens
        print("Watch goldens")
        func section17() async throws {
            let start = await BashTools.runBackground(command: "sleep 0.4; echo GOLDENMATCH; sleep 5")
            if let handle = payload(start)["handle"] as? String {
                let bad = await BackgroundProcessRegistry.shared.registerWatch(
                    handle: handle, pattern: "([a-z", limit: 1)
                var badOK = false
                if case .failure(let err) = bad, err.description.hasPrefix("invalid regex:") { badOK = true }
                check("watch invalid regex: failure with 'invalid regex:' prefix", badOK)

                let reg = await BackgroundProcessRegistry.shared.registerWatch(
                    handle: handle, pattern: "GOLDENMATCH", limit: 1)
                var watchId: String?
                if case .success(let id) = reg { watchId = id }
                check("watch id format watch_N", watchId?.hasPrefix("watch_") == true,
                      detail: watchId ?? "nil")

                var match: BackgroundProcessRegistry.WatchMatch?
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let events = await BackgroundProcessRegistry.shared.drainWatchMatches()
                    if let m = events.first(where: { $0.watchId == watchId }) { match = m; break }
                }
                let matchFields = match.map {
                    "pattern=\($0.pattern) line=\($0.line) stream=\($0.stream) auto=\($0.autoUnsubscribed) reason=\($0.unsubscribeReason ?? "nil") n=\($0.matchesSoFar)/\($0.limit)"
                } ?? "NO MATCH"
                check("watch match event: pinned fields incl. limit auto-unsubscribe",
                      matchFields == "pattern=GOLDENMATCH line=GOLDENMATCH stream=stdout auto=true reason=limit_reached n=1/1",
                      detail: matchFields)

                // A second watch that never matches: process exit must emit
                // the synthetic auto-unsubscribe event with pinned wording.
                let reg2 = await BackgroundProcessRegistry.shared.registerWatch(
                    handle: handle, pattern: "NEVERMATCHTOKEN", limit: 5)
                var watch2Id: String?
                if case .success(let id) = reg2 { watch2Id = id }
                _ = await BashTools.kill(handle: handle)
                var exitEvent: BackgroundProcessRegistry.WatchMatch?
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    let events = await BackgroundProcessRegistry.shared.drainWatchMatches()
                    if let m = events.first(where: { $0.watchId == watch2Id }) { exitEvent = m; break }
                }
                let exitFields = exitEvent.map {
                    "line=\($0.line) stream=\($0.stream) auto=\($0.autoUnsubscribed) reason=\($0.unsubscribeReason ?? "nil")"
                } ?? "NO EVENT"
                check("watch process-exit event: pinned wording and fields",
                      exitFields == "line=[watch auto-unsubscribed — process exited] stream=system auto=true reason=process_exited",
                      detail: exitFields)

                _ = await awaitBackgroundExit(handle, seconds: 8)
                let regDead = await BackgroundProcessRegistry.shared.registerWatch(
                    handle: handle, pattern: "x", limit: 1)
                var deadOK = false
                if case .failure(let err) = regDead,
                   err.description == "process has already exited; cannot attach a watch" { deadOK = true }
                check("watch on exited handle: exact error description", deadOK)
                _ = await BackgroundProcessRegistry.shared.drainCompletions()
            } else {
                check("watch goldens", false, detail: "background spawn failed")
            }
        }
        try await section17()

        // MARK: 18. Redaction scope goldens (CredentialCatalog, owner decision 2026-09-02)
        print("\nRedaction scope goldens")
        func section18() async throws {
            let token = "5551234567:AAGoldenTokenValue_0123456789abcde"
            let opencodeKey = "sk-opencode-golden-visible-0123456789"
            try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: token)
            try KeychainHelper.save(key: ProviderProfiles.opencodeApiKeyKey, value: opencodeKey)
            defer {
                try? KeychainHelper.delete(key: KeychainHelper.telegramBotTokenKey)
                try? KeychainHelper.delete(key: ProviderProfiles.opencodeApiKeyKey)
            }
            let echoToken = await BashTools.runAttached(command: "printf '%s' '\(token)'")
            let tokenOut = payload(echoToken)["stdout"] as? String ?? "<no stdout>"
            check("bot token echoed through bash comes back redacted",
                  tokenOut == HarnessSecretStore.tokenPlaceholder, detail: tokenOut)
            let echoOpenCode = await BashTools.runAttached(command: "printf '%s' '\(opencodeKey)'")
            let opencodeOut = payload(echoOpenCode)["stdout"] as? String ?? "<no stdout>"
            check("OpenCode key echoed through bash comes back verbatim (deliberately visible)",
                  opencodeOut == opencodeKey, detail: opencodeOut)
            check("MCP result text uses the same set: token redacted",
                  ToolExecutor.redactedMCPText("t=\(token);") == "t=\(HarnessSecretStore.tokenPlaceholder);")
            check("MCP result text uses the same set: OpenCode key kept",
                  ToolExecutor.redactedMCPText(opencodeKey) == opencodeKey)
            let env = KeychainHelper.redactionEnvironment()
            check("redaction environment carries the token under its catalogue key",
                  env[KeychainHelper.telegramBotTokenKey] == token && env[ProviderProfiles.opencodeApiKeyKey] == nil,
                  detail: "\(env.keys.sorted())")
            try KeychainHelper.save(key: KeychainHelper.telegramBotTokenKey, value: "short")
            check("values shorter than 8 chars never enter the redaction set",
                  KeychainHelper.redactionEnvironment()[KeychainHelper.telegramBotTokenKey] == nil)
        }
        try await section18()

        if failures > 0 {
            print("\n\(failures) bash golden check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll bash golden checks passed")
    }
}
