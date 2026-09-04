import Foundation
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Network
import Security
#endif

/// Checks and requests the operating-system permissions Briglia needs to operate
/// unattended.
///
/// macOS: TCC permissions (Full Disk Access, Accessibility, Screen Recording,
/// Automation) can never be granted silently — the best we can do is
/// front-load every prompt into a one-time guided setup so the agent is never
/// interrupted while running.
///
/// Linux: there is no TCC. File access is ordinary Unix permissions, so Full
/// Disk Access is always "granted". The one thing that still silently kills an
/// unattended agent is automatic suspend, so the Linux surface is all about
/// detecting and disabling it (GNOME auto-suspend via gsettings, or masking
/// the systemd sleep targets on headless machines).
enum PermissionsService {

    enum PermissionState: Equatable {
        case granted
        case denied
        case notDetermined
        /// Status can't be read right now (e.g. automation target app not running).
        case unknown(String)

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested yet"
            case .unknown(let reason): return reason
            }
        }
    }

    private static func runCommand(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    #if os(macOS)

    struct AutomationTarget: Identifiable {
        let name: String
        let bundleID: String
        var id: String { bundleID }
    }

    /// Apps the agent commonly drives via AppleScript/osascript. Each one gets
    /// its own Automation consent prompt the first time it is targeted.
    static let automationTargets: [AutomationTarget] = [
        AutomationTarget(name: "System Events", bundleID: "com.apple.systemevents"),
        AutomationTarget(name: "Finder", bundleID: "com.apple.finder"),
        AutomationTarget(name: "Shortcuts Events", bundleID: "com.apple.shortcuts.events"),
        AutomationTarget(name: "Music", bundleID: "com.apple.Music"),
        AutomationTarget(name: "Safari", bundleID: "com.apple.Safari"),
        AutomationTarget(name: "Mail", bundleID: "com.apple.mail"),
        AutomationTarget(name: "Notes", bundleID: "com.apple.Notes"),
        AutomationTarget(name: "Calendar", bundleID: "com.apple.iCal"),
        AutomationTarget(name: "Reminders", bundleID: "com.apple.reminders"),
        AutomationTarget(name: "Photos", bundleID: "com.apple.Photos"),
        AutomationTarget(name: "Terminal", bundleID: "com.apple.Terminal"),
    ]

    // MARK: - Full Disk Access

    /// FDA can't be requested programmatically; we detect it by probing files
    /// that are only readable with the grant.
    static func fullDiskAccessGranted() -> Bool {
        let probes = [
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
        ]
        for path in probes {
            if let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                if (try? handle.read(upToCount: 1)) != nil { return true }
            }
        }
        return false
    }

    // MARK: - Accessibility

    static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system consent prompt (once) and registers the app in the
    /// Accessibility list so the user can toggle it on.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: - Automation (AppleEvents)

    static func automationState(bundleID: String) -> PermissionState {
        let status = determineAutomationPermission(bundleID: bundleID, askIfNeeded: false)
        switch status {
        case 0:
            return .granted
        case -1743: // errAEEventNotPermitted
            return .denied
        case -1744: // errAEEventWouldRequireUserConsent
            return .notDetermined
        case -600: // procNotFound — target must be running to query
            return .unknown("App not running")
        default:
            return .unknown("Status \(status)")
        }
    }

    /// Launches the target app hidden if needed, then triggers the Automation
    /// consent prompt. Blocking while the dialog is up, so callers run it off
    /// the main thread.
    static func requestAutomation(bundleID: String) async -> PermissionState {
        let launched = await launchIfNeeded(bundleID: bundleID)
        if launched {
            // Give a freshly launched app a moment to register its AE handler.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let status = await Task.detached(priority: .userInitiated) {
            determineAutomationPermission(bundleID: bundleID, askIfNeeded: true)
        }.value
        switch status {
        case 0: return .granted
        case -1743: return .denied
        case -600: return .unknown("App not available")
        default: return .unknown("Status \(status)")
        }
    }

    private static func determineAutomationPermission(bundleID: String, askIfNeeded: Bool) -> OSStatus {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = descriptor.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(
            aeDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askIfNeeded
        )
    }

    private static func launchIfNeeded(bundleID: String) async -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return false
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Local Network (macOS 15+)

    /// There is no query/request API for the Local Network permission; the
    /// prompt fires on first local traffic. Browsing Bonjour briefly forces it.
    static func triggerLocalNetworkPrompt() {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: NWParameters())
        browser.start(queue: .global(qos: .utility))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            browser.cancel()
        }
    }

    // MARK: - Automatic system sleep (remote availability)

    /// The agent answers from the phone only while the Mac is awake. On
    /// modern macOS the user-facing control that governs this lives in the
    /// Lock Screen settings: «Spegni lo schermo quando non attivo» (pmset
    /// `displaysleep`) — once the display turns off, the system follows it
    /// into sleep. Both timers (battery and power adapter, where present)
    /// must be «Mai» (0 = never). Returns minutes per power source; a value
    /// is nil when that section can't be read (desktops have no battery).
    static func displaySleepMinutes() -> (ac: Int?, battery: Int?) {
        guard let output = runCommand("/usr/bin/pmset", ["-g", "custom"]) else { return (nil, nil) }
        var inACSection = true // desktops print a single "AC Power:" section
        var acValue: Int?
        var batteryValue: Int?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("Power:") {
                inACSection = trimmed.hasPrefix("AC")
                continue
            }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "displaysleep", let value = Int(parts[1]) else { continue }
            if inACSection { acValue = value } else { batteryValue = value }
        }
        return (acValue, batteryValue)
    }

    static func hasInternalBattery() -> Bool {
        (runCommand("/usr/bin/pmset", ["-g", "batt"]) ?? "").contains("InternalBattery")
    }

    /// Opens the Lock Screen settings, where the «Spegni lo schermo quando
    /// non attivo» timers live.
    static func openLockScreenSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security?LockScreen",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    // MARK: - System Settings deep links

    enum SettingsPane: String {
        case fullDiskAccess = "Privacy_AllFiles"
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
        case localNetwork = "Privacy_LocalNetwork"
    }

    static func openSettings(_ pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Code signature (grant persistence)

    /// TCC ties grants to the app's code signature. An ad-hoc signature changes
    /// on every rebuild, which is why permissions keep being re-asked.
    static func signingSummary() -> (stable: Bool, description: String) {
        var codeRef: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &codeRef) == errSecSuccess, let code = codeRef else {
            return (false, "Signature unreadable")
        }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticRef) == errSecSuccess, let staticCode = staticRef else {
            return (false, "Signature unreadable")
        }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            return (false, "Signature unreadable")
        }
        if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String, !teamID.isEmpty {
            return (true, "Signed with a developer certificate (team \(teamID)) — grants persist across app updates.")
        }
        let certs = info[kSecCodeInfoCertificates as String] as? [Any] ?? []
        if certs.isEmpty {
            return (false, "Ad-hoc signature — macOS forgets these grants every time the app is rebuilt. Sign with a stable certificate to keep them permanent.")
        }
        return (true, "Signed with a local certificate — grants persist while the certificate stays the same.")
    }

    #else

    // MARK: - Linux

    /// No TCC on Linux: whatever the invoking user can read, Briglia can read.
    static func fullDiskAccessGranted() -> Bool { true }

    /// Everything the wizard and doctor need to reason about automatic
    /// suspend on this machine.
    struct LinuxSleepStatus {
        /// Desktop environment from XDG_CURRENT_DESKTOP ("GNOME", "KDE", …);
        /// nil on headless machines.
        let desktop: String?
        /// GNOME auto-suspend delay in MINUTES on AC power: 0 = never,
        /// nil = not readable (non-GNOME desktop or no gsettings).
        let acSuspendMinutes: Int?
        /// Same for battery power.
        let batterySuspendMinutes: Int?
        /// Whether systemd's sleep/suspend targets are masked (the headless
        /// way of making suspend impossible).
        let sleepTargetsMasked: Bool

        /// The honest verdict (plan §4.6): `neverSuspends` is gone — its
        /// rules inferred safety from missing information.
        var verdict: AutoSuspendCensus.Verdict { AutoSuspendCensus.currentVerdict() }
    }

    /// The three-level keep-awake verdict for this machine.
    static func autoSuspendVerdict() -> AutoSuspendCensus.Verdict {
        AutoSuspendCensus.currentVerdict()
    }

    static func linuxSleepStatus() -> LinuxSleepStatus {
        let desktop = ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"]

        var acMinutes: Int?
        var batteryMinutes: Int?
        if let gsettings = PlatformBinary.find("gsettings") {
            func gnomeSuspend(_ source: String) -> Int? {
                guard let type = runCommand(gsettings, ["get", "org.gnome.settings-daemon.plugins.power",
                                                        "sleep-inactive-\(source)-type"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if type.contains("nothing") { return 0 }
                guard let raw = runCommand(gsettings, ["get", "org.gnome.settings-daemon.plugins.power",
                                                       "sleep-inactive-\(source)-timeout"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      let seconds = Int(raw.components(separatedBy: " ").last ?? raw) else { return nil }
                return seconds == 0 ? 0 : max(1, seconds / 60)
            }
            acMinutes = gnomeSuspend("ac")
            batteryMinutes = gnomeSuspend("battery")
        }

        var masked = false
        if let systemctl = PlatformBinary.find("systemctl"),
           let output = runCommand(systemctl, ["is-enabled", "sleep.target"]) {
            masked = output.trimmingCharacters(in: .whitespacesAndNewlines) == "masked"
        }

        return LinuxSleepStatus(
            desktop: desktop,
            acSuspendMinutes: acMinutes,
            batterySuspendMinutes: batteryMinutes,
            sleepTargetsMasked: masked
        )
    }

    /// Keep-awake parity with the macOS wizard: report the GNOME auto-suspend
    /// timers as "display sleep minutes". Non-GNOME/headless → (nil, nil).
    static func displaySleepMinutes() -> (ac: Int?, battery: Int?) {
        let status = linuxSleepStatus()
        return (status.acSuspendMinutes, status.batterySuspendMinutes)
    }

    static func hasInternalBattery() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/sys/class/power_supply")) ?? []
        return entries.contains { $0.hasPrefix("BAT") }
    }

    /// Turn GNOME auto-suspend off for both power sources. Returns true when
    /// gsettings accepted both writes.
    static func disableGnomeAutoSuspend() -> Bool {
        guard let gsettings = PlatformBinary.find("gsettings") else { return false }
        var ok = true
        for source in ["ac", "battery"] {
            let result = runCommand(gsettings, ["set", "org.gnome.settings-daemon.plugins.power",
                                                "sleep-inactive-\(source)-type", "nothing"])
            if result == nil { ok = false }
        }
        return ok
    }

    /// Mask the systemd sleep targets so the machine can never suspend —
    /// the right call for a dedicated headless agent box. Needs sudo, which
    /// prompts on the wizard's terminal (stdio is inherited on purpose).
    static func maskLinuxSleepTargets() -> Bool {
        guard let sudo = PlatformBinary.find("sudo") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sudo)
        process.arguments = ["systemctl", "mask",
                             "sleep.target", "suspend.target", "hibernate.target", "hybrid-sleep.target"]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    #endif
}
