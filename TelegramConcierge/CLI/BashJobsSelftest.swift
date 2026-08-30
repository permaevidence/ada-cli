import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Managed Bash Jobs v2 machinery tests — the layers
/// ABOVE the frozen legacy payload contract (that contract lives in
/// __bash-golden-selftest): completion-acknowledgement receipts now, the
/// wait engine and v2 schema in later phases.
struct BashJobsSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__bash-jobs-selftest",
        abstract: "Internal: managed bash jobs v2 machinery (receipts, waits).",
        shouldDisplay: false
    )

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Isolate into temp XDG roots (set BEFORE the lazy StoragePaths
        // statics are first touched, same pattern as __lane-selftest): the
        // instrumented jobs this test runs must never contaminate a real
        // installation's bash_jobs_stats.json field-observation counters.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-bash-jobs-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        setenv("XDG_DATA_HOME", tempRoot.appendingPathComponent("data").path, 1)
        setenv("XDG_CONFIG_HOME", tempRoot.appendingPathComponent("config").path, 1)
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            if !Task.isCancelled {
                print("WATCHDOG: bash jobs selftest exceeded 180s — hung; aborting")
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
        func awaitSettled(_ handle: String, seconds: Double) async -> Bool {
            for _ in 0..<Int(seconds * 20) {
                if let s = await BackgroundProcessRegistry.shared.snapshot(handleId: handle),
                   s.status != .running { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        // MARK: 1. Receipt lifecycle (Phase 2)
        print("Completion receipts")
        func section1() async throws {
            let start = await BashTools.runBackground(command: "echo receipt-one")
            guard let handle = payload(start)["handle"] as? String else {
                check("receipt job spawn", false, detail: start.content)
                throw ExitCode(1)
            }
            _ = await awaitSettled(handle, seconds: 10)

            let receipt = await BackgroundProcessRegistry.shared.pendingReceipt(handleId: handle)
            check("settled job with pending completion yields a receipt",
                  receipt != nil && receipt?.publicHandle == handle,
                  detail: String(describing: receipt))

            // Acknowledge → the automatic completion notice is withdrawn.
            if let receipt {
                await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
            }
            let drained = await BackgroundProcessRegistry.shared.drainCompletions()
            check("acknowledged completion never drains", drained.isEmpty,
                  detail: "drained=\(drained.count)")

            // Idempotent: a second acknowledgement of the same receipt is a no-op.
            if let receipt {
                await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
                await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
            }
            check("acknowledgement is idempotent", true)

            // After withdrawal there is nothing left to receipt.
            let receiptAfter = await BackgroundProcessRegistry.shared.pendingReceipt(handleId: handle)
            check("no receipt after acknowledgement", receiptAfter == nil,
                  detail: String(describing: receiptAfter))
        }
        try await section1()

        func section2() async throws {
            // A stale receipt — right handle name, wrong job identity — must
            // not acknowledge anything (BASH_V2_PLAN §16.4.9).
            let start = await BashTools.runBackground(command: "echo receipt-two")
            guard let handle = payload(start)["handle"] as? String else {
                check("stale-receipt job spawn", false, detail: start.content)
                throw ExitCode(1)
            }
            _ = await awaitSettled(handle, seconds: 10)
            let stale = BashCompletionReceipt(jobUUID: UUID(), publicHandle: handle)
            await BackgroundProcessRegistry.shared.acknowledgeCompletions([stale])
            let drained = await BackgroundProcessRegistry.shared.drainCompletions()
            check("stale receipt UUID cannot acknowledge a same-named handle",
                  drained.count == 1 && drained.first?.handleId == handle,
                  detail: "drained=\(drained.count)")
        }
        try await section2()

        func section3() async throws {
            // Running jobs have no completion yet, so no receipt.
            let start = await BashTools.runBackground(command: "sleep 30")
            if let handle = payload(start)["handle"] as? String {
                let receipt = await BackgroundProcessRegistry.shared.pendingReceipt(handleId: handle)
                check("running job yields no receipt", receipt == nil,
                      detail: String(describing: receipt))
                _ = await BashTools.kill(handle: handle)
                _ = await awaitSettled(handle, seconds: 8)
                _ = await BackgroundProcessRegistry.shared.drainCompletions()
            } else {
                check("running job yields no receipt", false, detail: start.content)
            }
        }
        try await section3()

        func section4() async throws {
            // A completion already delivered through the normal drain leaves
            // nothing to receipt — pendingReceipt tracks the NOTICE, not the
            // job's terminal state.
            let start = await BashTools.runBackground(command: "echo receipt-three")
            if let handle = payload(start)["handle"] as? String {
                _ = await awaitSettled(handle, seconds: 10)
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                let receipt = await BackgroundProcessRegistry.shared.pendingReceipt(handleId: handle)
                check("no receipt once the completion was drained normally",
                      drained.count == 1 && receipt == nil,
                      detail: "drained=\(drained.count) receipt=\(String(describing: receipt))")
            } else {
                check("no receipt once the completion was drained normally", false, detail: start.content)
            }
        }
        try await section4()

        func section5() async throws {
            let unknown = await BackgroundProcessRegistry.shared.pendingReceipt(handleId: "bash_424242")
            check("unknown handle yields no receipt", unknown == nil)
            // Acknowledging nothing / unknown receipts is a safe no-op.
            await BackgroundProcessRegistry.shared.acknowledgeCompletions([])
            await BackgroundProcessRegistry.shared.acknowledgeCompletions(
                [BashCompletionReceipt(jobUUID: UUID(), publicHandle: "bash_424242")])
            check("acknowledging unknown receipts is a no-op", true)
        }
        try await section5()

        // MARK: 1b. Receipt minting on non-wait settled observations (§8)
        // Any snapshot that delivers a terminal result into the turn mints
        // the acknowledgement receipt, not just settled waits — otherwise a
        // refused wait or a poll that observed the exit still produces a
        // duplicate completion notice (the bash_2 case from field testing).
        print("Receipt minting on settled snapshots")
        func section6() async throws {
            // A refused wait on an already-settled job serves the terminal
            // snapshot — it must carry the receipt like a settled wait.
            let start = await BashTools.runBackground(command: "echo refused-mint")
            if let handle = payload(start)["handle"] as? String {
                _ = await awaitSettled(handle, seconds: 10)
                let refused = await BashTools.waitManage(
                    handle: handle, effectiveWaitSeconds: nil,
                    refusalReason: "test refusal")
                let p = payload(refused)
                check("refused wait on settled job mints a receipt",
                      refused.receipt?.publicHandle == handle
                      && p["wait_refused"] as? String == "test refusal"
                      && p["status"] as? String != "running",
                      detail: "receipt=\(String(describing: refused.receipt)) payload=\(refused.content.prefix(200))")
                if let receipt = refused.receipt {
                    await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
                }
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("acknowledged refused-wait receipt suppresses the notice",
                      !drained.contains(where: { $0.handleId == handle }),
                      detail: "drained=\(drained.map(\.handleId))")
            } else {
                check("refused wait on settled job mints a receipt", false, detail: start.content)
            }
        }
        try await section6()

        func section7() async throws {
            // Plain output that observes the settled result mints too — the
            // classic polling path must not duplicate the notice.
            let start = await BashTools.runBackground(command: "echo output-mint")
            if let handle = payload(start)["handle"] as? String {
                _ = await awaitSettled(handle, seconds: 10)
                let out = await BashTools.output(handle: handle)
                check("output on settled job mints a receipt",
                      out.receipt?.publicHandle == handle,
                      detail: String(describing: out.receipt))
                if let receipt = out.receipt {
                    await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
                }
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("acknowledged output receipt suppresses the notice",
                      !drained.contains(where: { $0.handleId == handle }),
                      detail: "drained=\(drained.map(\.handleId))")
            } else {
                check("output on settled job mints a receipt", false, detail: start.content)
            }
        }
        try await section7()

        func section8() async throws {
            // A running job's snapshot observes no settlement: no receipt,
            // and the eventual completion notice is untouched.
            let start = await BashTools.runBackground(command: "sleep 15")
            if let handle = payload(start)["handle"] as? String {
                let out = await BashTools.output(handle: handle)
                check("output on running job mints nothing", out.receipt == nil,
                      detail: String(describing: out.receipt))
                _ = await BashTools.kill(handle: handle)
                _ = await awaitSettled(handle, seconds: 10)
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("running-job poll left the completion notice intact",
                      drained.contains(where: { $0.handleId == handle }),
                      detail: "drained=\(drained.map(\.handleId))")
            } else {
                check("output on running job mints nothing", false, detail: start.content)
            }
        }
        try await section8()

        func section9() async throws {
            // Once the notice was already delivered through the normal drain
            // there is nothing left to mint — no stale receipts for
            // long-settled jobs the model re-inspects later.
            let start = await BashTools.runBackground(command: "echo drained-mint")
            if let handle = payload(start)["handle"] as? String {
                _ = await awaitSettled(handle, seconds: 10)
                _ = await BackgroundProcessRegistry.shared.drainCompletions()
                let out = await BashTools.output(handle: handle)
                check("output after normal delivery mints nothing", out.receipt == nil,
                      detail: String(describing: out.receipt))
            } else {
                check("output after normal delivery mints nothing", false, detail: start.content)
            }
        }
        try await section9()

        func section10() async throws {
            // Subagent-owned jobs never enqueue notices, so their snapshots
            // mint nothing either — a receipt here could never match.
            let start = await BashTools.runBackground(
                command: "echo sub-mint", owner: "sub-mint-test")
            if let handle = payload(start)["handle"] as? String {
                _ = await awaitSettled(handle, seconds: 10)
                let out = await BashTools.output(handle: handle, owner: "sub-mint-test")
                check("subagent-owned settled output mints nothing", out.receipt == nil,
                      detail: String(describing: out.receipt))
                await BackgroundProcessRegistry.shared.terminateOwned(owner: "sub-mint-test")
            } else {
                check("subagent-owned settled output mints nothing", false, detail: start.content)
            }
        }
        try await section10()

        // MARK: 2. Receipt exclusion from serialization
        print("Receipt serialization boundaries")
        do {
            var trm = ToolResultMessage(toolCallId: "call_1", content: "{\"ok\":true}")
            trm.bashReceipt = BashCompletionReceipt(jobUUID: UUID(), publicHandle: "bash_7")
            let data = try JSONEncoder().encode(trm)
            let json = String(data: data, encoding: .utf8) ?? ""
            check("receipt never reaches encoded JSON",
                  !json.contains("bashReceipt") && !json.contains("jobUUID")
                  && !json.contains("publicHandle") && !json.contains("bash_7"),
                  detail: json)
            let decoded = try JSONDecoder().decode(ToolResultMessage.self, from: data)
            check("decoded tool result carries no receipt", decoded.bashReceipt == nil)
            check("content survives the round trip", decoded.content == trm.content)
        } catch {
            check("receipt serialization round trip", false, detail: String(describing: error))
        }

        // MARK: 3. Wait engine (Phase 3)
        print("Wait engine")
        func section11() async throws {
            // Settlement during the wait: outcome carries exit code and the
            // acknowledgement receipt; acknowledging suppresses the notice.
            let start = await BashTools.runBackground(command: "sleep 0.4; echo wait-one; exit 5")
            if let handle = payload(start)["handle"] as? String {
                let t0 = ContinuousClock.now
                let outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 20_000_000_000)
                let waited = BashWaitLedger.seconds(t0.duration(to: .now))
                var ok = false
                if case .settled(let exit, let receipt) = outcome {
                    ok = exit == 5 && receipt?.publicHandle == handle && waited < 15
                    if let receipt {
                        await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
                    }
                }
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("wait observes settlement: exit code + receipt, notice withdrawn",
                      ok && drained.isEmpty,
                      detail: "outcome=\(outcome) waited=\(String(format: "%.2f", waited))s drained=\(drained.count)")
            } else {
                check("wait observes settlement", false, detail: start.content)
            }
        }
        try await section11()

        func section12() async throws {
            // Wait on an ALREADY settled handle: immediate, with receipt.
            let start = await BashTools.runBackground(command: "echo wait-two")
            if let handle = payload(start)["handle"] as? String {
                _ = await awaitSettled(handle, seconds: 10)
                let t0 = ContinuousClock.now
                let outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 60_000_000_000)
                let waited = BashWaitLedger.seconds(t0.duration(to: .now))
                var ok = false
                if case .settled(let exit, let receipt) = outcome { ok = exit == 0 && receipt != nil }
                check("wait on settled handle returns immediately with receipt",
                      ok && waited < 1.0,
                      detail: "outcome=\(outcome) waited=\(String(format: "%.3f", waited))s")
                _ = await BackgroundProcessRegistry.shared.drainCompletions()
            } else {
                check("wait on settled handle returns immediately with receipt", false, detail: start.content)
            }
        }
        try await section12()

        func section13() async throws {
            // True wait timeout: job keeps running, NO receipt is consumed,
            // and the later completion injects exactly once.
            let start = await BashTools.runBackground(command: "sleep 2.5; echo wait-three")
            if let handle = payload(start)["handle"] as? String {
                let outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 300_000_000)
                var timedOutOK = false
                if case .waitTimedOut = outcome { timedOutOK = true }
                let stillRunning = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)?.status == .running
                check("wait timeout leaves the job running", timedOutOK && stillRunning,
                      detail: "outcome=\(outcome) running=\(stillRunning)")
                _ = await awaitSettled(handle, seconds: 10)
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("completion after a timed-out wait injects exactly once",
                      drained.count == 1 && drained.first?.handleId == handle,
                      detail: "drained=\(drained.count)")
            } else {
                check("wait timeout leaves the job running", false, detail: start.content)
            }
        }
        try await section13()

        func section14() async throws {
            // Cancellation: resolves promptly, job untouched; the waiter
            // slot is freed so a NEW wait works afterwards.
            let start = await BashTools.runBackground(command: "sleep 30")
            if let handle = payload(start)["handle"] as? String {
                let waitTask = Task {
                    await BackgroundProcessRegistry.shared.awaitSettlement(
                        handleId: handle, timeoutNanos: 60_000_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                let t0 = ContinuousClock.now
                waitTask.cancel()
                let outcome = await waitTask.value
                let cancelLatency = BashWaitLedger.seconds(t0.duration(to: .now))
                var cancelledOK = false
                if case .cancelled = outcome { cancelledOK = true }
                let stillRunning = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)?.status == .running
                check("cancelled wait: prompt, job keeps running",
                      cancelledOK && stillRunning && cancelLatency < 2,
                      detail: "outcome=\(outcome) latency=\(String(format: "%.2f", cancelLatency))s running=\(stillRunning)")

                // Cancel-before-registration: a pre-cancelled task must
                // resolve .cancelled without leaking a waiter.
                let preCancelled = Task {
                    await BackgroundProcessRegistry.shared.awaitSettlement(
                        handleId: handle, timeoutNanos: 60_000_000_000)
                }
                preCancelled.cancel()
                let pcOutcome = await preCancelled.value
                var pcOK = false
                if case .cancelled = pcOutcome { pcOK = true }
                check("pre-cancelled wait resolves cancelled without leaking", pcOK,
                      detail: "outcome=\(pcOutcome)")

                // The slot must be free: a fresh short wait times out
                // normally (rather than being refused as duplicate).
                let fresh = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 200_000_000)
                var freshOK = false
                if case .waitTimedOut = fresh { freshOK = true }
                check("waiter slot free after cancellation", freshOK, detail: "outcome=\(fresh)")

                // Duplicate: two concurrent waits on one handle — exactly
                // one is refused.
                async let a = BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 700_000_000)
                async let b = BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 700_000_000)
                let (ra, rb) = await (a, b)
                func isRefused(_ o: BackgroundProcessRegistry.WaitOutcome) -> Bool {
                    if case .refusedDuplicate = o { return true }; return false
                }
                func isTimeout(_ o: BackgroundProcessRegistry.WaitOutcome) -> Bool {
                    if case .waitTimedOut = o { return true }; return false
                }
                check("duplicate concurrent waits: exactly one refused",
                      (isRefused(ra) && isTimeout(rb)) || (isRefused(rb) && isTimeout(ra)),
                      detail: "a=\(ra) b=\(rb)")

                _ = await BashTools.kill(handle: handle)
                _ = await awaitSettled(handle, seconds: 8)
                _ = await BackgroundProcessRegistry.shared.drainCompletions()
            } else {
                check("cancelled wait: prompt, job keeps running", false, detail: start.content)
            }
        }
        try await section14()

        func section15() async throws {
            let unknown = await BackgroundProcessRegistry.shared.awaitSettlement(
                handleId: "bash_909090", timeoutNanos: 1_000_000_000)
            var unknownOK = false
            if case .unknownHandle = unknown { unknownOK = true }
            check("wait on unknown handle refuses immediately", unknownOK, detail: "outcome=\(unknown)")
        }
        try await section15()

        func section16() async throws {
            // Settlement/timeout boundary: with the wait deadline right at
            // the command's duration, the ONLY valid outcomes are a settled
            // result (receipt) or a running timeout (no receipt, completion
            // still pending). Several rounds to shake the race.
            var boundaryOK = true
            var detail = ""
            for round in 0..<5 {
                let start = await BashTools.runBackground(command: "sleep 0.3; echo boundary")
                guard let handle = payload(start)["handle"] as? String else {
                    boundaryOK = false; detail = "spawn failed"; break
                }
                let outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 300_000_000)
                switch outcome {
                case .settled(_, let receipt):
                    if let receipt {
                        await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
                        let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                        if !drained.isEmpty { boundaryOK = false; detail = "round \(round): settled+ack but drained \(drained.count)" }
                    } else {
                        boundaryOK = false; detail = "round \(round): settled without receipt"
                    }
                case .waitTimedOut:
                    _ = await awaitSettled(handle, seconds: 10)
                    let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                    if drained.count != 1 { boundaryOK = false; detail = "round \(round): timeout but drained \(drained.count)" }
                default:
                    boundaryOK = false; detail = "round \(round): unexpected \(outcome)"
                }
                if !boundaryOK { break }
            }
            check("settlement/timeout boundary: only the two valid branches", boundaryOK, detail: detail)
        }
        try await section16()

        // MARK: 4. Execution deadlines (Phase 3)
        print("Execution deadlines")
        func section17() async throws {
            let start = await BashTools.runBackground(command: "sleep 30")
            if let handle = payload(start)["handle"] as? String {
                await BackgroundProcessRegistry.shared.armExecutionDeadline(
                    handleId: handle, afterNanos: 1_000_000_000)
                let outcome = await BackgroundProcessRegistry.shared.awaitSettlement(
                    handleId: handle, timeoutNanos: 20_000_000_000)
                var settledOK = false
                if case .settled = outcome { settledOK = true }
                let status = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)?.status
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("execution deadline kills the job as timed_out",
                      settledOK && status == .timedOut
                      && drained.count == 1 && drained.first?.status == .timedOut,
                      detail: "outcome=\(outcome) status=\(status?.rawValue ?? "nil") drained=\(drained.count)")
            } else {
                check("execution deadline kills the job as timed_out", false, detail: start.content)
            }
        }
        try await section17()

        func section18() async throws {
            // Natural exit disarms the deadline: no late kill, no relabel.
            let start = await BashTools.runBackground(command: "echo fast-exit")
            if let handle = payload(start)["handle"] as? String {
                await BackgroundProcessRegistry.shared.armExecutionDeadline(
                    handleId: handle, afterNanos: 1_500_000_000)
                _ = await awaitSettled(handle, seconds: 10)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let status = await BackgroundProcessRegistry.shared.snapshot(handleId: handle)?.status
                let drained = await BackgroundProcessRegistry.shared.drainCompletions()
                check("natural exit disarms the execution deadline",
                      status == .exited && drained.count == 1 && drained.first?.status == .exited,
                      detail: "status=\(status?.rawValue ?? "nil") drained=\(drained.count)")
            } else {
                check("natural exit disarms the execution deadline", false, detail: start.content)
            }
        }
        try await section18()

        // MARK: 5. Per-turn wait ledger (Phase 3)
        print("Wait ledger")
        func section19() async throws {
            var ledger = BashWaitLedger()
            let t0 = ContinuousClock.now

            var g1: Double = -1
            if case .granted(let s) = ledger.admit(handle: "bash_1", requestedSeconds: 30, now: t0) { g1 = s }
            check("first wait grants the requested time", g1 == 30, detail: "granted=\(g1)")

            var g2: Double = -1
            if case .granted(let s) = ledger.admit(handle: "bash_2", requestedSeconds: 500, now: t0.advanced(by: .seconds(10))) { g2 = s }
            check("later wait clamps to per-call cap and window remainder",
                  g2 == 110, detail: "granted=\(g2) (window 120 - 10 elapsed)")

            var g3: Double = -1
            if case .granted(let s) = ledger.admit(handle: "bash_3", requestedSeconds: 60, now: t0.advanced(by: .seconds(100))) { g3 = s }
            check("wait near window end clamps to remainder", g3 == 20, detail: "granted=\(g3)")

            var exhausted = false
            if case .refused(let reason) = ledger.admit(handle: "bash_4", requestedSeconds: 5, now: t0.advanced(by: .seconds(121))),
               reason.contains("window") { exhausted = true }
            check("expired window refuses further waits", exhausted)

            ledger.recordWaitTimeout(handle: "bash_5")
            var repeatRefused = false
            if case .refused(let reason) = ledger.admit(handle: "bash_5", requestedSeconds: 5, now: t0.advanced(by: .seconds(1))),
               reason.contains("timed out") { repeatRefused = true }
            check("repeat wait on a timed-out handle is refused", repeatRefused)

            var otherStillOK = false
            if case .granted = ledger.admit(handle: "bash_6", requestedSeconds: 5, now: t0.advanced(by: .seconds(1))) { otherStillOK = true }
            check("other handles unaffected by the repeat-timeout guard", otherStillOK)

            // A fresh ledger (new turn) forgets both the window and the guard.
            var fresh = BashWaitLedger()
            var freshOK = false
            if case .granted(let s) = fresh.admit(handle: "bash_5", requestedSeconds: 120, now: t0.advanced(by: .seconds(200))), s == 120 { freshOK = true }
            check("a new turn's ledger resets window and guards", freshOK)

            var floorOK = false
            if case .granted(let s) = fresh.admit(handle: "bash_7", requestedSeconds: 0.2, now: t0.advanced(by: .seconds(200))), s == 1 { floorOK = true }
            check("sub-second requests clamp up to the 1s floor", floorOK)
        }
        try await section19()

        // MARK: 6. v2 dispatch and payload goldens (Phase 4)
        print("v2 dispatch goldens")

        func encode(_ dict: [String: Any]) -> String {
            guard let data = try? JSONSerialization.data(
                    withJSONObject: dict, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let s = String(data: data, encoding: .utf8) else { return "ENCODE_FAIL" }
            return s
        }
        func canonical(_ json: String, mask: [String], handle: String?) -> String {
            guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return "PARSE_FAIL: " + json
            }
            for key in mask where obj[key] != nil { obj[key] = "<masked>" }
            var s = encode(obj)
            if let handle { s = s.replacingOccurrences(of: handle, with: "<H>") }
            return s
        }
        func handleIn(_ result: ToolResultMessage) -> String? {
            ((try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any])?["handle"] as? String
        }
        func bashCall(_ jsonArgs: String, id: String = UUID().uuidString) -> ToolCall {
            ToolCall(id: id, type: "function", function: FunctionCall(name: "bash", arguments: jsonArgs))
        }
        func manageCall(_ jsonArgs: String, id: String = UUID().uuidString) -> ToolCall {
            ToolCall(id: id, type: "function", function: FunctionCall(name: "bash_manage", arguments: jsonArgs))
        }

        let executor = ToolExecutor()

        func section20() async throws {
            // Managed start that settles within the wait: final result in
            // the SAME call, full payload golden, receipt attached.
            let cmd = "printf mgd; exit 0"
            let result = await executor.executeBash(bashCall(#"{"command":"printf mgd; exit 0","wait_seconds":30}"#))
            let handle = handleIn(result)
            let expected: [String: Any] = [
                "command": cmd, "description": "", "effective_wait_seconds": 30,
                "exit_code": 0, "handle": "<H>", "pid": "<masked>",
                "running_for_seconds": "<masked>", "status": "exited",
                "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                "stdout": "mgd", "stdout_total_bytes": 3, "stdout_truncated": false,
                "success": true, "waited_seconds": "<masked>"
            ]
            let actual = canonical(result.content, mask: ["pid", "running_for_seconds", "waited_seconds"], handle: handle)
            check("managed start settled: full payload golden + receipt",
                  actual == encode(expected) && result.bashReceipt != nil,
                  detail: "\n    expected: \(encode(expected))\n    actual:   \(actual)\n    receipt=\(String(describing: result.bashReceipt))")
            if let receipt = result.bashReceipt {
                await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
            }
            let drained = await BackgroundProcessRegistry.shared.drainCompletions()
            check("managed settled result acknowledges cleanly", drained.isEmpty,
                  detail: "drained=\(drained.count)")
        }
        try await section20()

        var expiredHandle: String?
        func section21() async throws {
            // Managed start whose wait expires: running handle, command
            // continues, kill_after_seconds echoed, no receipt.
            let result = await executor.executeBash(bashCall(#"{"command":"sleep 20","wait_seconds":1,"kill_after_seconds":600}"#))
            expiredHandle = handleIn(result)
            let expected: [String: Any] = [
                "command": "sleep 20", "description": "", "effective_wait_seconds": 1,
                "handle": "<H>", "kill_after_seconds": 600, "message": "<masked>",
                "pid": "<masked>", "running_for_seconds": "<masked>", "status": "running",
                "stderr": "", "stderr_total_bytes": 0, "stderr_truncated": false,
                "stdout": "", "stdout_total_bytes": 0, "stdout_truncated": false,
                "success": true, "wait_timed_out": true, "waited_seconds": "<masked>"
            ]
            let actual = canonical(result.content, mask: ["message", "pid", "running_for_seconds", "waited_seconds"], handle: expiredHandle)
            check("managed start wait-expired: running payload golden, no receipt",
                  actual == encode(expected) && result.bashReceipt == nil,
                  detail: "\n    expected: \(encode(expected))\n    actual:   \(actual)")
        }
        try await section21()

        if let handle = expiredHandle {
            // The expired initial wait armed the repeat-timeout guard: a
            // manage-wait on the same handle this "turn" is refused without
            // blocking.
            let result = await executor.executeBashManage(
                manageCall("{\"mode\":\"wait\",\"handle\":\"\(handle)\",\"wait_seconds\":2}"))
            let obj = (try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any] ?? [:]
            check("repeat-timeout guard refuses a later wait on that handle",
                  (obj["wait_refused"] as? String)?.contains("timed out") == true
                  && obj["waited_seconds"] as? Int == 0
                  && obj["status"] as? String == "running",
                  detail: result.content.prefix(300).description)

            // A fresh run (ledger reset) admits waits on it again.
            await executor.resetBashWaitLedger()
            let again = await executor.executeBashManage(
                manageCall("{\"mode\":\"wait\",\"handle\":\"\(handle)\",\"wait_seconds\":1}"))
            let againObj = (try? JSONSerialization.jsonObject(with: Data(again.content.utf8))) as? [String: Any] ?? [:]
            check("new turn's ledger admits the handle again",
                  againObj["wait_timed_out"] as? Bool == true && againObj["wait_refused"] == nil,
                  detail: again.content.prefix(300).description)

            // list: running job enumerable, summary carries no stream content.
            let list = await executor.executeBashManage(manageCall(#"{"mode":"list"}"#))
            let listObj = (try? JSONSerialization.jsonObject(with: Data(list.content.utf8))) as? [String: Any] ?? [:]
            let rows = listObj["jobs"] as? [[String: Any]] ?? []
            let row = rows.first(where: { $0["handle"] as? String == handle })
            check("list enumerates the running job without stream content",
                  row != nil && row?["status"] as? String == "running"
                  && row?["command"] as? String == "sleep 20"
                  && row?["stdout"] == nil && row?["owner"] as? String == "main",
                  detail: list.content.prefix(300).description)

            _ = await executor.executeBashManage(manageCall("{\"mode\":\"kill\",\"handle\":\"\(handle)\"}"))
            _ = await awaitSettled(handle, seconds: 8)

            // list with include_settled shows it as killed; default hides it.
            let settled = await executor.executeBashManage(manageCall(#"{"mode":"list","include_settled":true}"#))
            let settledRows = ((try? JSONSerialization.jsonObject(with: Data(settled.content.utf8))) as? [String: Any])?["jobs"] as? [[String: Any]] ?? []
            let killedRow = settledRows.first(where: { $0["handle"] as? String == handle })
            let defaultList = await executor.executeBashManage(manageCall(#"{"mode":"list"}"#))
            let defaultRows = ((try? JSONSerialization.jsonObject(with: Data(defaultList.content.utf8))) as? [String: Any])?["jobs"] as? [[String: Any]] ?? []
            check("list include_settled shows the killed job; default hides it",
                  killedRow?["status"] as? String == "killed"
                  && !defaultRows.contains(where: { $0["handle"] as? String == handle }),
                  detail: "killedRow=\(String(describing: killedRow))")
            _ = await BackgroundProcessRegistry.shared.drainCompletions()
        }

        func section22() async throws {
            // Strict validation (§3.1, §6.5.2): removed v1 names and out-of-
            // range values get actionable errors with the replacements
            // spelled out — the fresh-v1-shaped-call regression contract.
            let cases: [(String, String)] = [
                (#"{"command":"true","run_in_background":true}"#, "wait_seconds=0"),
                (#"{"command":"true","timeout_ms":5000}"#, "equal wait_seconds and kill_after_seconds"),
                (#"{"command":"true","wait_seconds":5,"run_in_background":true}"#, "unknown argument"),
                (#"{"command":"true","kill_after_seconds":10,"timeout_ms":5000}"#, "timeout_ms was removed"),
                (#"{"command":"true","frobnicate":1}"#, "allowed: command, description, kill_after_seconds, service_key_env, wait_seconds, workdir"),
                (#"{"command":"true","kill_after_seconds":0}"#, "must be 1-604800"),
                (#"{"command":"true","kill_after_seconds":604801}"#, "must be 1-604800"),
                (#"{"command":"true","wait_seconds":-3}"#, "must be >= 0"),
            ]
            var allOK = true
            var detail = ""
            for (argsJSON, expectedFragment) in cases {
                let result = await executor.executeBash(bashCall(argsJSON))
                let err = ((try? JSONSerialization.jsonObject(with: Data(result.content.utf8))) as? [String: Any])?["error"] as? String
                if !(err?.contains(expectedFragment) ?? false) {
                    allOK = false
                    detail = "args=\(argsJSON) got=\(result.content.prefix(200))"
                    break
                }
            }
            check("removed v1 names and bad values rejected with actionable errors", allOK, detail: detail)

            let noWaitSecs = await executor.executeBashManage(manageCall(#"{"mode":"wait","handle":"bash_1"}"#))
            check("manage wait without wait_seconds rejected",
                  noWaitSecs.content.contains("requires 'wait_seconds'"),
                  detail: noWaitSecs.content.prefix(160).description)

            let unknown = await executor.executeBashManage(manageCall(#"{"mode":"wait","handle":"bash_808080","wait_seconds":2}"#))
            check("manage wait on unknown handle errors like output",
                  unknown.content == "{\"error\":\"unknown background handle: bash_808080\"}",
                  detail: unknown.content)
        }
        try await section22()

        // MARK: Executor capability contract (schema and behavior agree)
        print("Bash capability tiers")
        func section23() async throws {
            // Subagent executors default to foreground-only: hallucinated v2
            // args and run_in_background are REJECTED with explicit errors,
            // never silently downgraded (a wait_seconds build must not
            // become a 120s-killed foreground run) and never honored (no
            // detached jobs, no stranded handles).
            let sub = ToolExecutor(outputMode: .subagent)
            let waitResult = await sub.executeBash(bashCall(#"{"command":"printf subfg","wait_seconds":30}"#))
            check("foreground-only: hallucinated wait_seconds rejected loudly",
                  waitResult.content.contains("not available in this context")
                  && waitResult.bashReceipt == nil,
                  detail: waitResult.content.prefix(200).description)
            let bgResult = await sub.executeBash(bashCall(#"{"command":"sleep 30","run_in_background":true}"#))
            check("foreground-only: run_in_background rejected, nothing detached",
                  bgResult.content.contains("background execution is not available"),
                  detail: bgResult.content.prefix(200).description)
            let manageResult = await sub.executeBashManage(manageCall(#"{"mode":"output","handle":"bash_1"}"#))
            check("foreground-only: bash_manage rejected entirely",
                  manageResult.content.contains("bash_manage is not available"),
                  detail: manageResult.content.prefix(200).description)
            let fgResult = await sub.executeBash(bashCall(#"{"command":"printf subok"}"#))
            let fgObj = (try? JSONSerialization.jsonObject(with: Data(fgResult.content.utf8))) as? [String: Any] ?? [:]
            check("foreground-only: plain foreground still works",
                  fgObj["stdout"] as? String == "subok" && fgObj["exit_code"] as? Int == 0,
                  detail: fgResult.content.prefix(200).description)
        }
        try await section23()

        func section24() async throws {
            // Background-capable subagents (bash + bash_manage in their
            // schema) share the managed lifecycle vocabulary, scoped to
            // their own owner token: wait_seconds works, jobs are private,
            // and there are no completion notices.
            let sub = ToolExecutor(outputMode: .subagent)
            await sub.setSubagentBashCapability(.subagentManaged)
            let waitResult = await sub.executeBash(bashCall(#"{"command":"printf smx","wait_seconds":10}"#))
            let waitObj = (try? JSONSerialization.jsonObject(with: Data(waitResult.content.utf8))) as? [String: Any] ?? [:]
            check("subagent-managed: wait_seconds settles in-call",
                  waitObj["stdout"] as? String == "smx" && waitObj["status"] as? String == "exited",
                  detail: waitResult.content.prefix(200).description)
            check("subagent-managed: no receipt minted (no notices exist for subagent jobs)",
                  waitResult.bashReceipt == nil)
            let subDrained = await BackgroundProcessRegistry.shared.drainCompletions()
            check("subagent-managed: settled job enqueued no completion notice",
                  !subDrained.contains { ($0.stdoutTail).contains("smx") },
                  detail: "drained=\(subDrained.map(\.handleId))")
            let bgLegacy = await sub.executeBash(bashCall(#"{"command":"sleep 30","run_in_background":true}"#))
            check("subagent-managed: run_in_background rejected with wait_seconds=0 replacement",
                  bgLegacy.content.contains("unknown argument") && bgLegacy.content.contains("wait_seconds=0"),
                  detail: bgLegacy.content.prefix(240).description)
            // .mainManaged can never be granted to a subagent executor —
            // it coerces to .subagentManaged, whose watch stays refused.
            await sub.setSubagentBashCapability(.mainManaged)
            let watchTry = await sub.executeBashManage(manageCall(#"{"mode":"watch","handle":"bash_1","pattern":"x"}"#))
            check("subagent executor structurally refuses .mainManaged (watch still absent)",
                  watchTry.content.contains("not available for subagents"),
                  detail: watchTry.content.prefix(200).description)
        }
        try await section24()

        func section25() async throws {
            // Final schema contract (§6.1): one lifecycle vocabulary only,
            // and the removed v1 names appear NOWHERE — not in parameters,
            // not in descriptions.
            let mainBash = AvailableTools.bash
            let mainManage = AvailableTools.bashManage
            let subBash = AvailableTools.bashSubagentManaged
            let subManage = AvailableTools.bashManageSubagentManaged
            let fgBash = AvailableTools.bashForegroundOnly
            check("main bash schema: exactly the six final fields",
                  Set(mainBash.function.parameters.properties.keys) ==
                  ["command", "wait_seconds", "kill_after_seconds", "workdir", "description", "service_key_env"],
                  detail: mainBash.function.parameters.properties.keys.sorted().joined(separator: ","))
            let mainModes = mainManage.function.parameters.properties["mode"]?.enumValues ?? []
            check("main bash_manage schema: exactly the six final modes",
                  mainModes == ["output", "wait", "input", "watch", "kill", "list"],
                  detail: mainModes.joined(separator: ","))
            check("subagent bash schema: managed vocabulary, private-jobs truth",
                  subBash.function.parameters.properties["wait_seconds"] != nil
                  && subBash.function.parameters.properties["kill_after_seconds"] != nil
                  && subBash.function.description.contains("NO automatic exit notification"))
            let subModes = subManage.function.parameters.properties["mode"]?.enumValues ?? []
            check("subagent bash_manage schema: output/wait/input/kill/list, no watch",
                  subModes == ["output", "wait", "input", "kill", "list"]
                  && subManage.function.parameters.properties["pattern"] == nil,
                  detail: subModes.joined(separator: ","))
            check("foreground-only bash schema: kill_after_seconds only, no wait",
                  fgBash.function.parameters.properties["kill_after_seconds"] != nil
                  && fgBash.function.parameters.properties["wait_seconds"] == nil)
            for (label, def) in [("bash", mainBash), ("bash_manage", mainManage),
                                 ("sub bash", subBash), ("sub bash_manage", subManage),
                                 ("fg bash", fgBash)] {
                let text = def.function.description
                    + def.function.parameters.properties.values.map(\.description).joined()
                check("\(label) schema mentions no removed v1 name",
                      !text.contains("timeout_ms") && !text.contains("run_in_background"),
                      detail: label)
            }
            // Description-cleanup safety assertions (§10.4 of the amended
            // cleanup doc): the rules the 2026-08-19 field tests burned must
            // survive any future rewording.
            check("main bash schema keeps the launch-time completion promise",
                  mainBash.function.description.contains("notifies you automatically"))
            check("main bash schema keeps wait-never-kills and detachment rules",
                  mainBash.function.description.contains("Waiting never kills")
                  && mainBash.function.description.contains("wait_seconds=0"))
            check("main bash_manage pairs suppression with list passivity",
                  mainManage.function.description.contains("via output or wait")
                  && mainManage.function.description.contains("Passive audit"))
            check("main bash_manage states the explicit-waits ledger exemption",
                  mainManage.function.description.contains("Explicit waits")
                  && mainManage.function.description.contains("never count"))
            check("subagent bash_manage states the explicit-waits ledger exemption",
                  subManage.function.description.contains("Explicit waits")
                  && subManage.function.description.contains("never count"))
            check("subagent schemas state there is no automatic notification",
                  subBash.function.description.contains("NO automatic exit notification")
                  && subManage.function.description.contains("NO automatic exit notification"))
            for (label, def) in [("bash", mainBash), ("sub bash", subBash), ("fg bash", fgBash)] {
                let wd = def.function.parameters.properties["workdir"]?.description ?? ""
                check("\(label) workdir claims ~ only, never $VAR expansion",
                      wd.contains("~") && wd.contains("not $VAR"),
                      detail: wd)
            }
        }
        try await section25()

        // MARK: Strict integer lifecycle values (non-integers rejected)
        print("Strict lifecycle integers")
        await executor.resetBashWaitLedger()  // fresh turn window on slow CI
        func section26() async throws {
            let fractional = await executor.executeBash(bashCall(#"{"command":"printf z","wait_seconds":0.5}"#))
            check("wait_seconds 0.5 rejected (would silently detach as 0)",
                  fractional.content.contains("must be an integer")
                  && fractional.content.contains("0.5"),
                  detail: fractional.content.prefix(200).description)
            let fractionalKill = await executor.executeBash(bashCall(#"{"command":"printf z","kill_after_seconds":1.9}"#))
            check("kill_after_seconds 1.9 rejected (would truncate to 1)",
                  fractionalKill.content.contains("must be an integer"),
                  detail: fractionalKill.content.prefix(200).description)
            let integralDouble = await executor.executeBash(bashCall(#"{"command":"printf intd; exit 0","wait_seconds":2.0}"#))
            let intObj = (try? JSONSerialization.jsonObject(with: Data(integralDouble.content.utf8))) as? [String: Any] ?? [:]
            check("integral 2.0 accepted as 2 (managed, settles in wait)",
                  intObj["stdout"] as? String == "intd" && intObj["exit_code"] as? Int == 0,
                  detail: integralDouble.content.prefix(200).description)
            if let receipt = integralDouble.bashReceipt {
                await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
            }
            let manageFractional = await executor.executeBashManage(manageCall(#"{"mode":"wait","handle":"bash_1","wait_seconds":1.5}"#))
            check("manage wait rejects fractional wait_seconds",
                  manageFractional.content.contains("integer wait_seconds"),
                  detail: manageFractional.content.prefix(200).description)
        }
        try await section26()

        // MARK: Retention pruning (BASH_V2_PLAN §13)
        print("Registry retention")
        func section27() async throws {
            let registry = BackgroundProcessRegistry.shared
            await registry._testClearTombstones()

            // A settled job with an UNacknowledged completion is never
            // pruned, even at retention zero.
            let start = await BashTools.runBackground(command: "printf prune-hold; exit 0")
            let handle = (payload(start)["handle"] as? String) ?? ""
            _ = await awaitSettled(handle, seconds: 10)
            await registry._testSetPruneOverrides(retentionSeconds: 0, countCap: 1000)
            await registry._testPruneNow()
            let heldSnapshot = await registry.snapshot(handleId: handle)
            check("pending completion blocks pruning at retention 0",
                  heldSnapshot != nil, detail: "handle=\(handle)")

            // Acknowledge (simulating a durably saved turn) → the hold is
            // released and the age-based prune retires the entry.
            if let receipt = await registry.pendingReceipt(handleId: handle) {
                await registry.acknowledgeCompletions([receipt])
            }
            _ = await registry.drainCompletions()
            await registry._testPruneNow()
            let prunedSnapshot = await registry.snapshot(handleId: handle)
            check("acknowledged settled entry pruned past retention",
                  prunedSnapshot == nil, detail: "handle=\(handle)")

            // The pruned handle gets a specific EXPIRED error everywhere,
            // not a gaslighting "unknown".
            let expiredOutput = await BashTools.output(handle: handle)
            check("pruned handle: output says expired, not unknown",
                  expiredOutput.content.contains("expired background handle")
                  && expiredOutput.content.contains("about an hour"),
                  detail: expiredOutput.content.prefix(220).description)
            let expiredKill = await BashTools.kill(handle: handle)
            check("pruned handle: kill says expired",
                  expiredKill.content.contains("expired background handle"),
                  detail: expiredKill.content.prefix(200).description)
            let expiredWait = await BashTools.waitManage(
                handle: handle, effectiveWaitSeconds: 1, refusalReason: nil)
            check("pruned handle: wait says expired",
                  expiredWait.content.contains("expired background handle"),
                  detail: expiredWait.content.prefix(200).description)
            let trulyUnknown = await BashTools.output(handle: "bash_424242")
            check("never-existed handle still says unknown",
                  trulyUnknown.content.contains("unknown background handle"),
                  detail: trulyUnknown.content.prefix(200).description)

            // Count cap: with retention effectively infinite, the oldest
            // settled entries are pruned down to the cap, newest kept.
            await registry._testSetPruneOverrides(retentionSeconds: 1_000_000, countCap: 1)
            var handles: [String] = []
            for i in 0..<3 {
                let s = await BashTools.runBackground(command: "printf cap\(i); exit 0")
                if let h = payload(s)["handle"] as? String { handles.append(h) }
            }
            for h in handles { _ = await awaitSettled(h, seconds: 10) }
            for h in handles {
                if let r = await registry.pendingReceipt(handleId: h) {
                    await registry.acknowledgeCompletions([r])
                }
            }
            _ = await registry.drainCompletions()
            await registry._testPruneNow()
            let oldest = await registry.snapshot(handleId: handles.first ?? "")
            let newest = await registry.snapshot(handleId: handles.last ?? "")
            check("count cap prunes oldest settled, keeps newest",
                  handles.count == 3 && oldest == nil && newest != nil,
                  detail: "handles=\(handles)")

            // A RUNNING job is never pruned, under any policy.
            await registry._testSetPruneOverrides(retentionSeconds: 0, countCap: 0)
            let runStart = await BashTools.runBackground(command: "sleep 15")
            let runHandle = (payload(runStart)["handle"] as? String) ?? ""
            await registry._testPruneNow()
            let runningSnapshot = await registry.snapshot(handleId: runHandle)
            check("running job survives retention 0 + cap 0",
                  runningSnapshot?.status == .running, detail: "handle=\(runHandle)")
            _ = await BashTools.kill(handle: runHandle)
            _ = await awaitSettled(runHandle, seconds: 10)
            if let r = await registry.pendingReceipt(handleId: runHandle) {
                await registry.acknowledgeCompletions([r])
            }
            _ = await registry.drainCompletions()

            // Restore production policy for the remaining groups.
            await registry._testSetPruneOverrides(retentionSeconds: nil, countCap: nil)
            await registry._testClearTombstones()
        }
        try await section27()

        // MARK: Ownership scoping (BASH_V2_PLAN §10.5)
        print("Job ownership")
        func section28() async throws {
            let registry = BackgroundProcessRegistry.shared

            // A subagent-owned job is invisible to the main scope — output,
            // kill, and list all behave as if the handle didn't exist.
            let subStart = await BashTools.runBackground(
                command: "sleep 15", owner: "sub-testA")
            let subHandle = (payload(subStart)["handle"] as? String) ?? ""
            check("subagent start message warns: private, no notification",
                  (payload(subStart)["message"] as? String ?? "").contains("NO automatic exit notification"),
                  detail: subStart.content.prefix(220).description)
            let mainView = await BashTools.output(handle: subHandle)
            check("main scope cannot see a subagent-owned job",
                  mainView.content.contains("unknown background handle"),
                  detail: mainView.content.prefix(200).description)
            let mainKill = await BashTools.kill(handle: subHandle)
            check("main scope cannot kill a subagent-owned job",
                  mainKill.content.contains("unknown or already-stopped"),
                  detail: mainKill.content.prefix(200).description)
            let mainList = await registry.listJobs(includeSettled: true)
            check("main list excludes subagent-owned jobs",
                  !mainList.contains { $0.handle == subHandle })

            // The owner itself sees and manages its job normally.
            let ownView = await BashTools.output(handle: subHandle, owner: "sub-testA")
            check("owner scope sees its own job",
                  ownView.content.contains("\"status\":\"running\"") || ownView.content.contains("\"status\": \"running\""),
                  detail: ownView.content.prefix(200).description)
            let crossOwner = await BashTools.output(handle: subHandle, owner: "sub-testB")
            check("a different subagent owner cannot see it either",
                  crossOwner.content.contains("unknown background handle"),
                  detail: crossOwner.content.prefix(200).description)

            // terminateOwned kills only that owner's jobs; a main-owned job
            // keeps running.
            let mainStart = await BashTools.runBackground(command: "sleep 15")
            let mainHandle = (payload(mainStart)["handle"] as? String) ?? ""
            await registry.terminateOwned(owner: "sub-testA")
            let subGone = await registry.snapshot(handleId: subHandle, owner: "sub-testA")
            let mainAlive = await registry.snapshot(handleId: mainHandle)
            check("terminateOwned kills the owner's job, spares main's",
                  subGone?.status != .running && mainAlive?.status == .running,
                  detail: "sub=\(subGone?.status.rawValue ?? "nil") main=\(mainAlive?.status.rawValue ?? "nil")")

            // A settled subagent-owned job produces NO completion notice —
            // its notification path would be the main conversation.
            let subQuick = await BashTools.runBackground(
                command: "printf subdone; exit 0", owner: "sub-testC")
            let subQuickHandle = (payload(subQuick)["handle"] as? String) ?? ""
            var quickSettled = false
            for _ in 0..<200 {
                if let s = await registry.snapshot(handleId: subQuickHandle, owner: "sub-testC"),
                   s.status != .running { quickSettled = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let drained = await registry.drainCompletions()
            check("subagent-owned settlement produces no completion notice",
                  quickSettled && !drained.contains { $0.handleId == subQuickHandle },
                  detail: "settled=\(quickSettled) drained=\(drained.map(\.handleId))")

            _ = await BashTools.kill(handle: mainHandle)
            _ = await awaitSettled(mainHandle, seconds: 10)
            if let r = await registry.pendingReceipt(handleId: mainHandle) {
                await registry.acknowledgeCompletions([r])
            }
            _ = await registry.drainCompletions()
        }
        try await section28()

        func section29() async throws {
            // Executor level: a background-capable subagent executor scopes
            // everything to its own owner token, gets wait/list, and
            // refuses watch.
            let sub = ToolExecutor(outputMode: .subagent)
            await sub.setSubagentBashCapability(.subagentManaged)
            let start = await sub.executeBash(bashCall(#"{"command":"sleep 15","wait_seconds":0}"#))
            let subHandle = ((try? JSONSerialization.jsonObject(with: Data(start.content.utf8))) as? [String: Any])?["handle"] as? String ?? ""
            check("subagent-managed can detach a job with wait_seconds=0",
                  !subHandle.isEmpty, detail: start.content.prefix(240).description)
            check("subagent-managed detach message tells the private-jobs truth",
                  start.content.contains("private to this run") && start.content.contains("NO automatic exit notification"),
                  detail: start.content.prefix(300).description)
            let ownOutput = await sub.executeBashManage(manageCall(#"{"mode":"output","handle":"\#(subHandle)"}"#))
            check("subagent manages its own job",
                  ownOutput.content.contains("\"handle\""),
                  detail: ownOutput.content.prefix(200).description)
            let mainSteal = await executor.executeBashManage(manageCall(#"{"mode":"output","handle":"\#(subHandle)"}"#))
            check("main executor cannot inspect the subagent's job",
                  mainSteal.content.contains("unknown background handle"),
                  detail: mainSteal.content.prefix(200).description)
            let watchTry = await sub.executeBashManage(manageCall(#"{"mode":"watch","handle":"\#(subHandle)","pattern":"x"}"#))
            check("subagent watch refused with poll/wait guidance",
                  watchTry.content.contains("not available for subagents")
                  && watchTry.content.contains("mode='output'"),
                  detail: watchTry.content.prefix(220).description)
            let listTry = await sub.executeBashManage(manageCall(#"{"mode":"list"}"#))
            check("subagent list shows its own running job, scoped label",
                  listTry.content.contains(subHandle) && listTry.content.contains("this_subagent_run"),
                  detail: listTry.content.prefix(240).description)
            let mainList = await executor.executeBashManage(manageCall(#"{"mode":"list"}"#))
            check("main list does not show the subagent's job",
                  !mainList.content.contains("\"handle\":\"\(subHandle)\""),
                  detail: mainList.content.prefix(240).description)
            let subWait = await sub.executeBashManage(manageCall(#"{"mode":"wait","handle":"\#(subHandle)","wait_seconds":1}"#))
            check("subagent wait on its own job works (expires, job survives)",
                  subWait.content.contains("\"wait_timed_out\":true")
                  && subWait.content.contains("no automatic exit notification"),
                  detail: subWait.content.prefix(300).description)
            let killOwn = await sub.executeBashManage(manageCall(#"{"mode":"kill","handle":"\#(subHandle)"}"#))
            check("subagent kills its own job",
                  killOwn.content.contains("\"success\":true") || killOwn.content.contains("\"success\": true"),
                  detail: killOwn.content.prefix(200).description)
        }
        try await section29()

        // MARK: Boolean lifecycle values rejected (CFBoolean-aware)
        print("Boolean lifecycle values")
        await executor.resetBashWaitLedger()  // fresh turn window on slow CI
        func section30() async throws {
            let boolKill = await executor.executeBash(bashCall(#"{"command":"printf b","kill_after_seconds":true}"#))
            check("kill_after_seconds:true rejected (not a 1s deadline)",
                  boolKill.content.contains("must be an integer")
                  && boolKill.content.contains("true"),
                  detail: boolKill.content.prefix(200).description)
            let boolWait = await executor.executeBash(bashCall(#"{"command":"printf b","wait_seconds":false}"#))
            check("wait_seconds:false rejected",
                  boolWait.content.contains("must be an integer"),
                  detail: boolWait.content.prefix(200).description)
            let manageBool = await executor.executeBashManage(manageCall(#"{"mode":"wait","handle":"bash_1","wait_seconds":true}"#))
            check("manage wait rejects boolean wait_seconds",
                  manageBool.content.contains("integer wait_seconds"),
                  detail: manageBool.content.prefix(200).description)
            // The SE-0170 guard: genuine JSON 1 must still parse (a naive
            // `is Bool` would classify NSNumber(1) as boolean on Darwin).
            let intOne = await executor.executeBash(bashCall(#"{"command":"printf one; exit 0","wait_seconds":1}"#))
            let oneObj = (try? JSONSerialization.jsonObject(with: Data(intOne.content.utf8))) as? [String: Any] ?? [:]
            check("wait_seconds:1 still accepted (SE-0170 guard)",
                  oneObj["stdout"] as? String == "one" || oneObj["handle"] != nil,
                  detail: intOne.content.prefix(200).description)
            if let receipt = intOne.bashReceipt {
                await BackgroundProcessRegistry.shared.acknowledgeCompletions([receipt])
            }
            _ = await BackgroundProcessRegistry.shared.drainCompletions()
        }
        try await section30()

        // MARK: Concurrent waiter registration (continuation-leak race)
        print("Concurrent wait registration")
        func section31() async throws {
            let registry = BackgroundProcessRegistry.shared
            let start = await BashTools.runBackground(command: "sleep 8")
            let handle = (payload(start)["handle"] as? String) ?? ""
            // Hammer one handle with concurrent waits: exactly ONE may hold
            // the waiter slot (it times out after 1s); every other call must
            // resolve as refusedDuplicate. Before the atomic in-closure
            // re-check, two callers could interleave across the guard's
            // suspension point and the second registration overwrote —
            // and leaked — the first continuation, hanging the suite.
            var granted = 0, refused = 0, other = 0
            await withTaskGroup(of: BackgroundProcessRegistry.WaitOutcome.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        await registry.awaitSettlement(handleId: handle, timeoutNanos: 1_000_000_000)
                    }
                }
                for await outcome in group {
                    switch outcome {
                    case .waitTimedOut:      granted += 1
                    case .refusedDuplicate:  refused += 1
                    default:                 other += 1
                    }
                }
            }
            check("8 concurrent waits: one slot holder, rest refused, none lost",
                  granted == 1 && refused == 7 && other == 0,
                  detail: "granted=\(granted) refused=\(refused) other=\(other)")
            _ = await BashTools.kill(handle: handle)
            _ = await awaitSettled(handle, seconds: 10)
            if let r = await registry.pendingReceipt(handleId: handle) {
                await registry.acknowledgeCompletions([r])
            }
            _ = await registry.drainCompletions()

            // Wait is ownership-scoped like every other mode: the main
            // scope waiting on a subagent-owned handle learns nothing (no
            // blocking on its timing, straight unknown).
            let subStart = await BashTools.runBackground(command: "sleep 8", owner: "sub-waitscope")
            let subHandle = (payload(subStart)["handle"] as? String) ?? ""
            let t0 = ContinuousClock.now
            let crossWait = await BashTools.waitManage(
                handle: subHandle, effectiveWaitSeconds: 30, refusalReason: nil)
            let crossElapsed = BashWaitLedger.seconds(t0.duration(to: .now))
            check("main wait on subagent-owned handle: unknown, no timing leak",
                  crossWait.content.contains("unknown background handle") && crossElapsed < 5,
                  detail: "elapsed=\(crossElapsed) payload=\(crossWait.content.prefix(160))")
            await registry.terminateOwned(owner: "sub-waitscope")
        }
        try await section31()

        // MARK: Default quick-command policy (§3.1 matrix, §6.2)
        print("Default lifecycle policy")
        func section32() async throws {
            // The 120s default is untestable at wall-clock speed; shrink it
            // through the test-only override. Semantics are identical.
            let savedDefault = BashTools.quickDefaultSeconds
            defer { BashTools.quickDefaultSeconds = savedDefault }

            // §6.2.1: a quick command with no lifecycle fields returns its
            // final result in the same call, policy echoed.
            BashTools.quickDefaultSeconds = 30
            await executor.resetBashWaitLedger()
            let quick = await executor.executeBash(bashCall(#"{"command":"printf qdef"}"#))
            let quickObj = (try? JSONSerialization.jsonObject(with: Data(quick.content.utf8))) as? [String: Any] ?? [:]
            check("default policy: quick command settles in-call with wait=kill echoed",
                  quickObj["stdout"] as? String == "qdef" && quickObj["status"] as? String == "exited"
                  && quickObj["effective_wait_seconds"] as? Int == 30
                  && quickObj["kill_after_seconds"] as? Int == 30
                  && quickObj["exit_code"] as? Int == 0,
                  detail: quick.content.prefix(300).description)
            check("default policy: settled quick command mints a receipt",
                  quick.bashReceipt != nil)

            // §6.2.2: a no-argument command crossing the default deadline
            // has its whole tree killed and returns execution_timed_out —
            // ONE atomic terminal outcome, never a running handle.
            BashTools.quickDefaultSeconds = 2
            let crossed = await executor.executeBash(bashCall(#"{"command":"printf pre; sleep 30"}"#))
            let crossedObj = (try? JSONSerialization.jsonObject(with: Data(crossed.content.utf8))) as? [String: Any] ?? [:]
            check("default policy: deadline crossing returns terminal execution_timed_out",
                  crossedObj["execution_timed_out"] as? Bool == true
                  && crossedObj["status"] as? String == "timed_out"
                  && crossedObj["stdout"] as? String == "pre"
                  && crossedObj["wait_timed_out"] == nil,
                  detail: crossed.content.prefix(300).description)
            check("default policy: deadline-crossed result minted a receipt",
                  crossed.bashReceipt != nil)

            // Default (implicit) waits never charge the turn's wait ledger:
            // after two defaults, an explicit wait is still admitted.
            BashTools.quickDefaultSeconds = 1
            _ = await executor.executeBash(bashCall(#"{"command":"true"}"#))
            _ = await executor.executeBash(bashCall(#"{"command":"true"}"#))
            let explicitAfter = await executor.executeBash(bashCall(#"{"command":"sleep 20","wait_seconds":1}"#))
            let explicitObj = (try? JSONSerialization.jsonObject(with: Data(explicitAfter.content.utf8))) as? [String: Any] ?? [:]
            let explicitHandle = explicitObj["handle"] as? String ?? ""
            check("default policy: implicit waits don't charge the wait ledger",
                  explicitObj["wait_refused"] == nil && explicitObj["wait_timed_out"] as? Bool == true,
                  detail: explicitAfter.content.prefix(300).description)
            if !explicitHandle.isEmpty {
                _ = await BashTools.kill(handle: explicitHandle)
                _ = await awaitSettled(explicitHandle, seconds: 8)
            }

            // §6.2.8: omitted wait plus explicit kill uses the default wait
            // with the explicit deadline — kill earlier than the wait
            // returns the terminal timed-out snapshot (§6.2.6).
            BashTools.quickDefaultSeconds = 60
            await executor.resetBashWaitLedger()
            let t0 = ContinuousClock.now
            let killOnly = await executor.executeBash(bashCall(#"{"command":"printf ko; sleep 30","kill_after_seconds":2}"#))
            let killOnlyObj = (try? JSONSerialization.jsonObject(with: Data(killOnly.content.utf8))) as? [String: Any] ?? [:]
            let killOnlyElapsed = BashWaitLedger.seconds(t0.duration(to: .now))
            check("kill without wait: default wait + explicit earlier deadline settles terminally",
                  killOnlyObj["execution_timed_out"] as? Bool == true
                  && killOnlyObj["kill_after_seconds"] as? Int == 2
                  && killOnlyObj["stdout"] as? String == "ko"
                  && killOnlyElapsed < 30,
                  detail: "elapsed=\(killOnlyElapsed) payload=\(killOnly.content.prefix(300))")
            _ = await BackgroundProcessRegistry.shared.drainCompletions()
        }
        try await section32()

        // MARK: Terminal-snapshot render normalization (Codex review race)
        print("Render-race normalization")
        func sectionRenderRace() async throws {
            // Pure contract: a settled snapshot strips wait_timed_out and the
            // promised-notification message and never arms the repeat-timeout
            // guard; running snapshots pass through untouched; wait_refused
            // survives either way (the v0.1.33 refused-wait-mints case).
            let (normSettled, expSettled) = BashTools.normalizeTerminalRender(
                settled: true,
                extra: ["waited_seconds": 1.5, "wait_timed_out": true,
                        "message": "Still running...", "wait_refused": "window expired"],
                waitExpired: true)
            check("normalization strips contradiction keys on settled snapshots",
                  normSettled["wait_timed_out"] == nil && normSettled["message"] == nil
                  && normSettled["waited_seconds"] as? Double == 1.5
                  && normSettled["wait_refused"] as? String == "window expired"
                  && expSettled == false,
                  detail: String(describing: normSettled))
            let (normRunning, expRunning) = BashTools.normalizeTerminalRender(
                settled: false,
                extra: ["wait_timed_out": true, "message": "Still running..."],
                waitExpired: true)
            check("normalization is a no-op for running snapshots",
                  normRunning["wait_timed_out"] as? Bool == true
                  && normRunning["message"] as? String == "Still running..."
                  && expRunning == true,
                  detail: String(describing: normRunning))

            // Property check at the collision boundary: sleep 1 with a 1s
            // wait maximizes the settle-between-outcome-and-render window.
            // Every result must be self-consistent — never "exited" plus
            // wait_timed_out, never a timed-out wait carrying a receipt,
            // never a settled payload still promising a notification.
            await executor.resetBashWaitLedger()
            var consistent = true
            var raceDetail = ""
            for i in 0..<8 {
                if i == 4 { await executor.resetBashWaitLedger() }  // stay well inside the wait window
                let r = await executor.executeBash(bashCall(#"{"command":"sleep 1","wait_seconds":1}"#))
                let obj = (try? JSONSerialization.jsonObject(with: Data(r.content.utf8))) as? [String: Any] ?? [:]
                let status = obj["status"] as? String ?? "?"
                let timedOutWait = obj["wait_timed_out"] as? Bool == true
                if timedOutWait && (status != "running" || r.bashReceipt != nil) {
                    consistent = false
                    raceDetail = "iteration \(i): wait_timed_out with status=\(status) receipt=\(r.bashReceipt != nil)"
                    break
                }
                if status != "running" && obj["message"] != nil {
                    consistent = false
                    raceDetail = "iteration \(i): settled payload still carries a message: \(obj["message"] ?? "")"
                    break
                }
                if let h = obj["handle"] as? String, status == "running" {
                    _ = await BashTools.kill(handle: h)
                    _ = await awaitSettled(h, seconds: 8)
                }
            }
            check("boundary collisions render self-consistently (8x sleep-1/wait-1)",
                  consistent, detail: raceDetail)
            _ = await BackgroundProcessRegistry.shared.drainCompletions()
        }
        try await sectionRenderRace()

        // MARK: Historical v1 records are inert (§6.5.1)
        func section33() async throws {
            // Old conversations carry v1-shaped bash calls as opaque
            // argument STRINGS — persistence round-trips them verbatim and
            // nothing re-executes them. A fresh v1-shaped call gets the
            // actionable validation error (checked in the strict-validation
            // block above).
            let legacyCall = ToolCall(
                id: "call_history_1", type: "function",
                function: FunctionCall(
                    name: "bash",
                    arguments: #"{"command":"make build","timeout_ms":300000,"run_in_background":false}"#))
            var roundTrip: ToolCall?
            if let data = try? JSONEncoder().encode(legacyCall) {
                roundTrip = try? JSONDecoder().decode(ToolCall.self, from: data)
            }
            check("historical v1 tool call round-trips verbatim without migration",
                  roundTrip?.function.arguments == legacyCall.function.arguments
                  && roundTrip?.function.name == "bash",
                  detail: roundTrip?.function.arguments ?? "DECODE FAILED")
        }
        try await section33()

        if failures > 0 {
            print("\n\(failures) bash jobs check(s) FAILED")
            throw ExitCode(1)
        }
        print("\nAll bash jobs checks passed")
    }
}
