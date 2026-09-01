import Foundation

// MARK: - Recurrence Type

enum RecurrenceType: Codable, Equatable {
    case daily
    case weekly
    case monthly
    case custom(minutes: Int)
    /// Specific days of the week. Days use ISO 8601 numbering: 1=Monday … 7=Sunday.
    case daysOfWeek(days: Set<Int>)

    // Human-readable description
    var description: String {
        switch self {
        case .daily: return "daily"
        case .weekly: return "weekly"
        case .monthly: return "monthly"
        case .custom(let minutes):
            if minutes >= 60 && minutes % 60 == 0 {
                let hours = minutes / 60
                return "every \(hours) hour\(hours > 1 ? "s" : "")"
            } else {
                return "every \(minutes) minute\(minutes > 1 ? "s" : "")"
            }
        case .daysOfWeek(let days):
            let sorted = days.sorted()
            if sorted == [1,2,3,4,5] { return "weekdays" }
            if sorted == [6,7] { return "weekends" }
            let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            return "every " + sorted.map { names[$0 - 1] }.joined(separator: ", ")
        }
    }

    /// Calculate the next trigger date based on recurrence type
    func nextTriggerDate(from date: Date) -> Date {
        let calendar = Calendar.current
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .custom(let minutes):
            return calendar.date(byAdding: .minute, value: minutes, to: date) ?? date
        case .daysOfWeek(let isoDays):
            // Convert ISO days (1=Mon..7=Sun) to Apple weekday (1=Sun..7=Sat)
            let appleDays = Set(isoDays.map { ($0 % 7) + 1 })
            for offset in 1...7 {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
                let weekday = calendar.component(.weekday, from: candidate)
                if appleDays.contains(weekday) {
                    return candidate
                }
            }
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
    }

    /// Snap an initial trigger date to a valid occurrence for this recurrence.
    /// For `.daysOfWeek`, advances to the nearest selected weekday on or after
    /// `date` (preserving the time of day); other cases return `date` unchanged.
    func alignedInitialTriggerDate(from date: Date) -> Date {
        guard case .daysOfWeek(let isoDays) = self else { return date }
        let calendar = Calendar.current
        let appleDays = Set(isoDays.map { ($0 % 7) + 1 })
        for offset in 0...6 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            if appleDays.contains(calendar.component(.weekday, from: candidate)) {
                return candidate
            }
        }
        return date
    }
}

// MARK: - Watcher Telemetry

/// Model-blind funnel counters persisted on the watcher row. Definitions:
/// "fires" are DELIVERED BATCHES (a 14-event
/// camera batch is one fire) — not raw events and not triage runs. Rolling
/// windows use persisted five-minute buckets (288 per day) so "fires in the
/// last hour" is exact and survives restarts.
struct WatcherTelemetry: Codable {
    /// One five-minute bucket of fire counts, keyed by its start instant.
    struct FireBucket: Codable {
        let start: Date
        var count: Int
    }

    static let bucketSeconds: TimeInterval = 300
    static let retentionSeconds: TimeInterval = 24 * 3600

    /// Polled script runs (scripted watchers only).
    var checks: Int = 0
    /// Delivered fire batches, lifetime.
    var fires: Int = 0
    /// Fires that reached the main agent (notify:main deliveries and triage
    /// NOTIFY verdicts).
    var notifies: Int = 0
    /// Consecutive triage SKIP verdicts since the last NOTIFY. Only triage
    /// updates this — a main-routed watcher's [SKIP] replies happen inside
    /// agent turns the harness does not parse.
    var consecutiveSkips: Int = 0
    /// Five-minute fire buckets, pruned past 24h on every mutation.
    var buckets: [FireBucket] = []
    /// Last time the deterministic runaway backstop injected its note, for
    /// rate-limiting (§5 layer 3).
    var lastBackstopNoteAt: Date?

    private static func bucketStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / bucketSeconds).rounded(.down) * bucketSeconds)
    }

    mutating func recordFire(at date: Date = Date()) {
        fires += 1
        let start = Self.bucketStart(for: date)
        if let index = buckets.firstIndex(where: { $0.start == start }) {
            buckets[index].count += 1
        } else {
            buckets.append(FireBucket(start: start, count: 1))
        }
        prune(now: date)
    }

    mutating func prune(now: Date = Date()) {
        buckets.removeAll { now.timeIntervalSince($0.start) > Self.retentionSeconds + Self.bucketSeconds }
    }

    func fires(inLast seconds: TimeInterval, now: Date = Date()) -> Int {
        buckets.filter { now.timeIntervalSince($0.start) <= seconds }.reduce(0) { $0 + $1.count }
    }

    var firesLastHour: Int { fires(inLast: 3600) }
    var firesLast24h: Int { fires(inLast: 24 * 3600) }

    /// Deterministic runaway backstop (§5 layer 3): fires at sustained
    /// high-frequency all-SKIP behavior, rate-limited to one note per 6h.
    /// "More than ~6/hour, mostly SKIP" is the pathological line; the hard
    /// threshold sits above it so the model-judgment layer (counters in the
    /// triage prompt) gets the first word.
    static let backstopFiresPerHour = 10
    static let backstopConsecutiveSkips = 10
    static let backstopNoteMinInterval: TimeInterval = 6 * 3600

    func backstopShouldFire(now: Date = Date()) -> Bool {
        guard fires(inLast: 3600, now: now) >= Self.backstopFiresPerHour,
              consecutiveSkips >= Self.backstopConsecutiveSkips else { return false }
        if let last = lastBackstopNoteAt, now.timeIntervalSince(last) < Self.backstopNoteMinInterval {
            return false
        }
        return true
    }

    /// One-line rendering injected into triage prompts and `list` output.
    func summaryLine(isScripted: Bool) -> String {
        var parts = [
            "fires last hour: \(firesLastHour)",
            "last 24h: \(firesLast24h)",
            "lifetime: \(fires)",
            "notifies: \(notifies)",
            "consecutive skips: \(consecutiveSkips)"
        ]
        if isScripted { parts.insert("checks: \(checks)", at: 0) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Reminder Model

struct Reminder: Codable, Identifiable {
    let id: UUID
    var triggerDate: Date
    let prompt: String          // Detailed instructions for future Gemini
    let createdAt: Date
    var triggered: Bool
    let recurrence: RecurrenceType?
    // Script-backed (conditional) reminders. All optional so reminders.json
    // files written before this feature still decode.
    /// Path of the agent-authored check script. When set, the schedule is a
    /// polling clock: the script runs at each due time and the reminder only
    /// fires (injects a message) when the script prints output.
    /// `var` (not `let`) since 2026-08-27: a Mind import restores rows whose
    /// paths point at the SOURCE installation's root — the post-import
    /// rebase rewrites them onto this install's reminder-scripts directory.
    var scriptPath: String?
    /// Scripted only: stop recurring after the first real fire ("tell me when
    /// CI finishes" — poll until it happens once, then self-delete).
    let deleteAfterFire: Bool?
    /// Scripted only: consecutive script failures, updated in place on the
    /// single standing row; at `ReminderService.maxConsecutiveScriptFailures`
    /// the watcher fires an error message and is deleted.
    var consecutiveFailures: Int?
    /// Scripted only: SHA-256 (hex) of the script source at creation time.
    /// Verified before every run — a mismatch means the file was modified
    /// outside `manage_reminders` (bypassing the creation gate and notice),
    /// so the watcher stops instead of executing tampered code.
    let scriptSHA256: String?
    /// Scripted only: set when the failure cap is reached. A paused watcher
    /// keeps its row, script and seen-state but is skipped by the due check;
    /// it can be re-armed via `manage_reminders` action='resume' (safe in any
    /// turn — resuming re-arms hash-verified, previously user-approved code,
    /// it cannot introduce new code).
    var paused: Bool?
    /// Scripted only: how many times this watcher was resumed without a single
    /// successful script run (exit 0) in between. Cleared on any successful
    /// run. Used to stop resume→fail→resume loops: after one fruitless resume
    /// the failure envelope tells the agent to stop resuming and involve the
    /// user instead.
    var resumesSinceLastSuccess: Int?
    /// Scripted only: set (together with `paused`) when this row arrived via
    /// a Mind import (Codex round 4, 2026-08-27). The archive's scripts and
    /// their expected hashes travel together, so no prior user approval can
    /// be assumed for this installation — while set, `manage_reminders`
    /// action='resume' REFUSES; only the user-typed /resumewatcher command
    /// clears the flag and re-arms. Durable in reminders.json so a restart
    /// can never forget a quarantine.
    var importQuarantined: Bool?
    /// External-trigger watchers: no schedule and no script — the watcher
    /// fires when an external process posts an event via `briglia trigger <id>`.
    /// `triggerDate` is pinned to the distant future so the clock-based due
    /// check never picks these rows up.
    let externalTrigger: Bool?
    /// External only: instant of the last delivered fire, driving the
    /// leading-edge + cooldown batching. Nil until the first fire.
    var lastExternalFireDate: Date?
    /// Watchers only: fire routing.
    /// nil or "main" = today's behavior (fires wake the main agent);
    /// "subagent" = a dedicated triage session bound to this watcher;
    /// "subagent:<name>" = a NAMED, shared triage session (the name IS the
    /// group — one parameter, not two).
    var notifyMode: String?
    /// Required when notifyMode routes to a subagent: the judgment-bar
    /// instructions the triage agent applies to every fire. Written and
    /// edited only in user-typed turns (like check scripts).
    var triageInstructions: String?
    /// SHA-256 (hex) of `triageInstructions` at creation/update through
    /// manage_reminders. Verified before every triage dispatch — a mismatch
    /// means the row was edited outside the gated tool, so the fire
    /// escalates to the main agent instead of running tampered instructions.
    var triageInstructionsSHA256: String?
    /// The bound triage subagent session, created lazily on the first
    /// dispatched fire. Surfaced in `list` so the main agent can resume the
    /// session and ask questions (pull complements push).
    var triageSessionId: String?
    /// Optional cheap-lane name ("cheap-vision"/"cheap-text") the triage
    /// subagent runs on; nil = inherit the main model. Snapshotted into each
    /// FireRecord at production — the record's captured lane governs a
    /// pending batch, like the captured instructions do. A lane the user has
    /// since unconfigured degrades to inherit at dispatch (never blocks a
    /// fire).
    var triageModelLane: String?
    /// Funnel counters (§5). Optional so pre-existing rows decode.
    var telemetry: WatcherTelemetry?

    var isScripted: Bool { scriptPath != nil }
    var isPaused: Bool { paused ?? false }
    var isImportQuarantined: Bool { importQuarantined ?? false }
    var isExternal: Bool { externalTrigger ?? false }
    /// The routing group name for `subagent:<name>` rows, nil otherwise.
    var triageGroup: String? {
        guard let mode = notifyMode, let colon = mode.firstIndex(of: ":"), mode.hasPrefix("subagent:") else { return nil }
        let name = String(mode[mode.index(after: colon)...])
        return name.isEmpty ? nil : name
    }
    var routesToTriage: Bool {
        (notifyMode ?? "main").hasPrefix("subagent")
    }

    init(
        id: UUID = UUID(),
        triggerDate: Date,
        prompt: String,
        recurrence: RecurrenceType? = nil,
        scriptPath: String? = nil,
        deleteAfterFire: Bool? = nil,
        consecutiveFailures: Int? = nil,
        scriptSHA256: String? = nil,
        externalTrigger: Bool? = nil,
        notifyMode: String? = nil,
        triageInstructions: String? = nil,
        triageInstructionsSHA256: String? = nil,
        triageModelLane: String? = nil
    ) {
        self.id = id
        self.triggerDate = triggerDate
        self.prompt = prompt
        self.createdAt = Date()
        self.triggered = false
        self.recurrence = recurrence
        self.scriptPath = scriptPath
        self.deleteAfterFire = deleteAfterFire
        self.consecutiveFailures = consecutiveFailures
        self.scriptSHA256 = scriptSHA256
        self.paused = nil
        self.resumesSinceLastSuccess = nil
        self.importQuarantined = nil
        self.externalTrigger = externalTrigger
        self.lastExternalFireDate = nil
        self.notifyMode = notifyMode
        self.triageInstructions = triageInstructions
        self.triageInstructionsSHA256 = triageInstructionsSHA256
        self.triageSessionId = nil
        self.triageModelLane = triageModelLane
        self.telemetry = nil
    }
}
