import Foundation

/// Run-scoped policy bounding how long one turn can silently block on bash
/// waits (BASH_V2_PLAN §9). A 120-second per-call cap is not a turn cap — a
/// model could chain waits across several handles — so the FIRST accepted
/// wait establishes `firstWaitTime + 120s` as the turn's wall-clock wait
/// deadline; later waits are clamped to the remaining window, and once it
/// passes, waits degrade to immediate refusals the model can act on.
///
/// A handle that produced one true wait timeout is refused further waits for
/// the REST OF THE TURN only — the guard resets with the next turn, because
/// a later explicit user turn may legitimately wait again (§9.4).
///
/// Owned by ToolExecutor, one per run; not thread-safe on its own (the
/// executor serializes bash-wait preflight in assistant tool-call order).
struct BashWaitLedger {
    /// Per-call and per-turn wall-clock cap, in seconds.
    static let waitWindowSeconds: Double = 120

    private var windowDeadline: ContinuousClock.Instant?
    private var timedOutHandles: Set<String> = []

    enum Admission: Equatable {
        /// Wait allowed for this many seconds (requested, clamped to the
        /// per-call cap and the turn window's remainder).
        case granted(effectiveSeconds: Double)
        /// Wait refused; the reason is model-actionable wording.
        case refused(reason: String)
    }

    /// Decide whether a wait on `handle` may block, and for how long.
    /// `now` is injectable for deterministic tests.
    mutating func admit(handle: String, requestedSeconds: Double,
                        now: ContinuousClock.Instant = .now) -> Admission {
        if timedOutHandles.contains(handle) {
            return .refused(reason: "a wait on \(handle) already timed out this turn — this job is long-running; end your turn and its result will be delivered automatically when it finishes")
        }
        let perCall = min(max(requestedSeconds, 1), Self.waitWindowSeconds)
        if let deadline = windowDeadline {
            let remaining = Self.seconds(now.duration(to: deadline))
            guard remaining > 0 else {
                return .refused(reason: "this turn's bash wait window (\(Int(Self.waitWindowSeconds))s wall-clock from the first wait) is exhausted — this call returns an immediate snapshot instead of blocking; job results will be delivered automatically")
            }
            return .granted(effectiveSeconds: min(perCall, remaining))
        }
        windowDeadline = now.advanced(by: .seconds(Self.waitWindowSeconds))
        return .granted(effectiveSeconds: perCall)
    }

    /// Record that a wait on `handle` genuinely expired (the job was still
    /// running). Later waits on that handle are refused this turn.
    mutating func recordWaitTimeout(handle: String) {
        timedOutHandles.insert(handle)
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
