import Foundation

/// Process-held keep-awake (macOS). A Mac sleeps by default; system sleep is
/// the ONE thing that stops a terminal-run `briglia` (App Nap never applies
/// to a terminal process, and display sleep is harmless). The chat, the
/// daemon and `briglia quicksetup` hold an idle-sleep assertion for their
/// lifetime — what `caffeinate -i` does — so no Energy Settings step is
/// needed. A closed lid or a manual sleep still sleeps the machine; the
/// wizard, doctor and the quick-setup page say so.
///
/// Linux: nothing to hold. Base Linux never auto-suspends by itself; the
/// evidence rule in `PermissionsService.autoSuspendVerdict()` covers the
/// desktop power managers (owner decision 2026-09-04: no inhibitor).
enum KeepAwake {
    /// The assertion name macOS shows in `pmset -g assertions`.
    static let defaultReason = "Briglia is running"

    nonisolated(unsafe) private static var activity: NSObjectProtocol?
    private static let lock = NSLock()

    /// Hold the idle-system-sleep assertion until `release()` or process exit.
    /// Idempotent.
    static func holdForProcessLifetime(reason: String = defaultReason) {
        #if os(macOS)
        lock.lock(); defer { lock.unlock() }
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: reason)
        #endif
    }

    /// Whether this process currently holds the assertion.
    static var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return activity != nil
    }

    /// Release the assertion (tests, and the quick-setup "don't start the
    /// chat" path is fine to leave it — process exit releases it anyway).
    static func release() {
        #if os(macOS)
        lock.lock(); defer { lock.unlock() }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        #endif
    }

    /// Evidence for the quick-setup keep-awake row and doctor: is an
    /// assertion with our reason listed by `pmset -g assertions` right now?
    /// nil on Linux (not applicable).
    static func assertionListedBySystem(reason: String = defaultReason) -> Bool? {
        #if os(macOS)
        guard let r = QuickSetupEvidence.quietRun("/usr/bin/pmset", ["-g", "assertions"], timeoutSeconds: 10), r.status == 0 else { return false }
        return r.stdout.contains("PreventUserIdleSystemSleep") && r.stdout.contains(reason)
        #else
        return nil
        #endif
    }
}
