import Foundation

/// The Linux keep-awake evidence rule (plan §2.6, §4.6, §6.3). Replaces
/// `LinuxSleepStatus.neverSuspends`, whose name promised a guarantee the
/// census cannot give and whose rules ("nil desktop ⇒ headless ⇒ cannot
/// suspend", "unreadable minutes ⇒ 0") failed open (Codex, 2026-09-04).
///
/// Three honest levels:
/// 1. **sleep impossible** — every sleep target is masked. The only level
///    that also covers manual sleep, lid closure and custom services.
/// 2. **no detected idle auto-suspend** — a headless machine (no desktop
///    session, no power-manager process, no active TLP, effective logind
///    `IdleAction=ignore`, no lid switch, no internal battery), or GNOME
///    with both sleep-inactive keys reading `'nothing'`.
/// 3. **may suspend** — everything else, with the reason.
///
/// The rule is pure over `Facts` so it runs on macOS in the selftest; the
/// Linux collector fills the facts from the real system.
enum AutoSuspendCensus {
    enum Verdict: Equatable {
        enum Evidence: Equatable {
            case headless(details: String)
            case gnomeNothing(lidPresent: Bool)
        }
        case sleepImpossible
        case noDetectedIdleAutoSuspend(Evidence)
        case maySuspend(reason: String)

        var isOK: Bool {
            if case .maySuspend = self { return false }
            return true
        }
        var key: String {
            switch self {
            case .sleepImpossible: return "sleep_impossible"
            case .noDetectedIdleAutoSuspend: return "no_detected_idle_auto_suspend"
            case .maySuspend: return "may_suspend"
            }
        }
        /// One line for the wizard, doctor and the quick-setup row.
        var summary: String {
            switch self {
            case .sleepImpossible:
                return "automatic suspend: impossible (sleep targets masked)"
            case .noDetectedIdleAutoSuspend(.headless(let details)):
                return "no idle auto-suspend detected (headless: \(details)) — a manual sleep, a closed lid or a custom service would still stop Briglia"
            case .noDetectedIdleAutoSuspend(.gnomeNothing(let lid)):
                return "no idle auto-suspend detected (GNOME: sleep-inactive-ac/battery = nothing) — a manual sleep\(lid ? ", closing the lid" : "") or a custom service would still stop Briglia"
            case .maySuspend(let reason):
                return "may suspend — \(reason)"
            }
        }
        static let maskCommand = "sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
    }

    /// What the census can read. `nil` means "could not be read", which is
    /// never evidence of safety.
    struct Facts: Equatable {
        /// `systemctl is-enabled` of the four targets, all == "masked".
        var allSleepTargetsMasked: Bool?
        var desktopSession: String?          // XDG_CURRENT_DESKTOP
        var displayPresent: Bool             // DISPLAY or WAYLAND_DISPLAY set
        var powerManagerProcesses: [String]? // matched names in the process table; nil = unreadable
        var tlpActive: Bool?
        var logindIdleAction: String?        // effective value; nil = unreadable
        var lidPresent: Bool?
        var internalBatteryPresent: Bool?
        var gnomeSleepInactiveAC: String?    // raw gsettings output; nil = unreadable/absent
        var gnomeSleepInactiveBattery: String?
        var gsettingsFailed: Bool
    }

    static let knownPowerManagers = ["gsd-power", "powerdevil", "xfce4-power-manager",
                                     "mate-power-manager", "csd-power"]

    static func verdict(for f: Facts) -> Verdict {
        if f.allSleepTargetsMasked == true { return .sleepImpossible }

        let isGnome = (f.desktopSession ?? "").uppercased().contains("GNOME")
        if isGnome {
            if f.gsettingsFailed { return .maySuspend(reason: "GNOME desktop but gsettings could not be read") }
            let ac = normalized(f.gnomeSleepInactiveAC), battery = normalized(f.gnomeSleepInactiveBattery)
            if ac == "nothing" && battery == "nothing" {
                return .noDetectedIdleAutoSuspend(.gnomeNothing(lidPresent: f.lidPresent == true))
            }
            let acText = ac ?? "unreadable", batteryText = battery ?? "unreadable"
            return .maySuspend(reason: "GNOME auto-suspend is on (sleep-inactive-ac-type=\(acText), sleep-inactive-battery-type=\(batteryText))")
        }

        let headlessSession = f.desktopSession == nil && !f.displayPresent
        guard headlessSession else {
            return .maySuspend(reason: "desktop session \(f.desktopSession ?? "unknown") with a power manager Briglia cannot read")
        }
        guard let pms = f.powerManagerProcesses else {
            return .maySuspend(reason: "the process table could not be read (power manager unknown)")
        }
        if !pms.isEmpty {
            return .maySuspend(reason: "power manager running: \(pms.joined(separator: ", "))")
        }
        if f.tlpActive == true { return .maySuspend(reason: "TLP is active") }
        guard let idle = f.logindIdleAction else {
            return .maySuspend(reason: "logind IdleAction could not be read")
        }
        if idle.lowercased() != "ignore" {
            return .maySuspend(reason: "logind IdleAction=\(idle)")
        }
        guard let lid = f.lidPresent else { return .maySuspend(reason: "lid switch state could not be read") }
        if lid { return .maySuspend(reason: "a lid switch is present (HandleLidSwitch defaults to suspend)") }
        guard let battery = f.internalBatteryPresent else { return .maySuspend(reason: "battery state could not be read") }
        if battery { return .maySuspend(reason: "an internal battery is present (laptop)") }
        let details = "no power manager, IdleAction ignore, no lid, no battery"
        return .noDetectedIdleAutoSuspend(.headless(details: details))
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return t.isEmpty ? nil : t
    }

    #if os(Linux)
    /// Selftest seam: substitute the collected facts.
    nonisolated(unsafe) static var factsOverride: Facts?

    static func collectFacts() -> Facts {
        if let factsOverride { return factsOverride }
        let env = ProcessInfo.processInfo.environment
        func run(_ name: String, _ args: [String]) -> (status: Int32, out: String)? {
            guard let path = PlatformBinary.find(name) else { return nil }
            let r = GoogleWorkspaceService.runBlockingProcess(executable: path, args: args, timeoutSeconds: 10)
            if let out = r.stdout { return (0, out) }
            if let detail = r.failureDetail, detail.hasPrefix("exit ") {
                return (1, r.stderrHead ?? "")
            }
            return nil
        }
        // 1. Masked targets.
        var masked: Bool?
        if let r = run("systemctl", ["is-enabled", "sleep.target", "suspend.target", "hibernate.target", "hybrid-sleep.target"]) {
            // is-enabled exits non-zero for masked units but prints one state per line.
            let states = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            masked = states.count == 4 && states.allSatisfy { $0 == "masked" }
        } else if let r = run("systemctl", ["is-enabled", "sleep.target"]) {
            masked = r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "masked"
        }
        // 2. Session.
        let desktop = env["XDG_CURRENT_DESKTOP"].flatMap { $0.isEmpty ? nil : $0 }
        let display = !(env["DISPLAY"] ?? "").isEmpty || !(env["WAYLAND_DISPLAY"] ?? "").isEmpty
        // 3. Power-manager processes (own user's), by comm name.
        var pms: [String]?
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") {
            var found: [String] = []
            let uid = getuid()
            for name in names where Int32(name) != nil {
                guard let comm = try? String(contentsOfFile: "/proc/\(name)/comm", encoding: .utf8) else { continue }
                var st = stat()
                guard stat("/proc/\(name)", &st) == 0, st.st_uid == uid else { continue }
                let c = comm.trimmingCharacters(in: .whitespacesAndNewlines)
                if knownPowerManagers.contains(where: { c.hasPrefix($0) }) { found.append(c) }
            }
            pms = Array(Set(found)).sorted()
        }
        // 4. TLP.
        var tlp: Bool?
        if let r = run("systemctl", ["is-active", "tlp"]) {
            tlp = r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
        } else { tlp = false }
        // 5. Effective IdleAction: merged config, last assignment wins.
        var idle: String?
        if let r = run("systemd-analyze", ["cat-config", "systemd/logind.conf"]) {
            idle = "ignore"  // documented default when unset
            for raw in r.out.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), line.hasPrefix("IdleAction=") else { continue }
                idle = String(line.dropFirst("IdleAction=".count)).trimmingCharacters(in: .whitespaces)
            }
        } else if let text = try? String(contentsOfFile: "/etc/systemd/logind.conf", encoding: .utf8) {
            idle = "ignore"
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), line.hasPrefix("IdleAction=") else { continue }
                idle = String(line.dropFirst("IdleAction=".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // 6. Lid switch.
        var lid: Bool?
        let fm = FileManager.default
        if let acpi = try? fm.contentsOfDirectory(atPath: "/proc/acpi/button/lid") {
            lid = !acpi.isEmpty
        } else if fm.fileExists(atPath: "/sys/class/input") {
            var any = false
            if let inputs = try? fm.contentsOfDirectory(atPath: "/sys/class/input") {
                for entry in inputs where entry.hasPrefix("event") {
                    let uevent = "/sys/class/input/\(entry)/device/uevent"
                    if let text = try? String(contentsOfFile: uevent, encoding: .utf8),
                       text.contains("SW=") && (text.lowercased().contains("lid") || text.contains("NAME=\"Lid Switch\"")) {
                        any = true
                    }
                    let namePath = "/sys/class/input/\(entry)/device/name"
                    if let n = try? String(contentsOfFile: namePath, encoding: .utf8), n.lowercased().contains("lid switch") { any = true }
                }
                lid = any
            }
        }
        // 7. Internal battery (scope != Device excludes wireless peripherals).
        var battery: Bool?
        if let supplies = try? fm.contentsOfDirectory(atPath: "/sys/class/power_supply") {
            var any = false
            for s in supplies {
                let type = (try? String(contentsOfFile: "/sys/class/power_supply/\(s)/type", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let scope = (try? String(contentsOfFile: "/sys/class/power_supply/\(s)/scope", encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if type == "Battery" && scope != "Device" { any = true }
            }
            battery = any
        }
        // 8. GNOME keys.
        var ac: String?, bat: String?, gsFailed = false
        if desktop?.uppercased().contains("GNOME") == true {
            if let gs = PlatformBinary.find("gsettings") {
                for (source, sink) in [("ac", 0), ("battery", 1)] {
                    let r = GoogleWorkspaceService.runBlockingProcess(
                        executable: gs, args: ["get", "org.gnome.settings-daemon.plugins.power", "sleep-inactive-\(source)-type"],
                        timeoutSeconds: 10)
                    guard let out = r.stdout else { gsFailed = true; continue }
                    if sink == 0 { ac = out } else { bat = out }
                }
            } else { gsFailed = true }
        }
        return Facts(allSleepTargetsMasked: masked, desktopSession: desktop, displayPresent: display,
                     powerManagerProcesses: pms, tlpActive: tlp, logindIdleAction: idle,
                     lidPresent: lid, internalBatteryPresent: battery,
                     gnomeSleepInactiveAC: ac, gnomeSleepInactiveBattery: bat, gsettingsFailed: gsFailed)
    }

    static func currentVerdict() -> Verdict { verdict(for: collectFacts()) }
    #endif
}
