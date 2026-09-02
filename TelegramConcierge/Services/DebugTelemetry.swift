import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// User-only diagnostic telemetry for the debug panel.
///
/// This telemetry is NEVER sent to the LLM — it is not added to messages, the
/// system prompt, tool results, or anything the model sees. It is purely an
/// in-memory, UI-side stream of events for diagnosing stuck-turn behavior and
/// other runtime anomalies (tool hangs, background completions, drop-on-busy
/// bugs, cancellations, etc.). The singleton is `@MainActor` so it can feed a
/// SwiftUI view directly; callers from actors/background tasks should use
/// the non-isolated `DebugTelemetry.log(...)` convenience which hops.
@MainActor
final class DebugTelemetry: ObservableObject {
    static let shared = DebugTelemetry()

    enum Kind: String, Codable {
        case toolStart
        case toolEnd
        case toolError
        case turnStart
        case turnEnd
        case turnCancelled
        case turnError
        case subagentSpawn
        case subagentComplete
        case bashSpawn
        case bashComplete
        case watchMatch
        case pollTick
        case busyReply
        case messageDrop
        case info
    }

    struct Event: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let kind: Kind
        let summary: String
        let detail: String?
        let durationMs: Int?
        let isError: Bool
    }

    @Published private(set) var events: [Event] = []
    @Published var verbose: Bool = false
    @Published var pinToBottom: Bool = true

    private let maxEvents = 500
    private let detailCap = 1000

    private init() {}

    /// Record a new event (main-actor only). Trims oldest if over capacity.
    func record(
        _ kind: Kind,
        summary: String,
        detail: String? = nil,
        durationMs: Int? = nil,
        isError: Bool = false
    ) {
        let clippedDetail: String? = {
            guard let d = detail else { return nil }
            if d.count <= detailCap { return d }
            return String(d.prefix(detailCap)) + "…"
        }()
        let event = Event(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            summary: summary,
            detail: clippedDetail,
            durationMs: durationMs,
            isError: isError
        )
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Convenience for paired start/end timing. The returned closure is called on
    /// completion with the terminating kind (e.g., `.toolEnd` / `.toolError`),
    /// optional detail, and `isError`.
    func begin(
        _ kind: Kind,
        summary: String,
        detail: String? = nil
    ) -> (Kind, String?, Bool) -> Void {
        let startedAt = Date()
        record(kind, summary: summary, detail: detail)
        return { [weak self] endKind, endDetail, isError in
            guard let self else { return }
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            self.record(endKind, summary: summary, detail: endDetail, durationMs: ms, isError: isError)
        }
    }

    func clear() {
        events.removeAll()
    }

    // MARK: - Non-isolated convenience (auto-hops to main actor)

    /// Log an event from any isolation context. Hops to the main actor to
    /// mutate the published list.
    nonisolated static func log(
        _ kind: Kind,
        summary: String,
        detail: String? = nil,
        durationMs: Int? = nil,
        isError: Bool = false
    ) {
        Task { @MainActor in
            DebugTelemetry.shared.record(
                kind,
                summary: summary,
                detail: detail,
                durationMs: durationMs,
                isError: isError
            )
        }
    }
}

/// Persistent success/failure counters for the file-editing tools
/// (apply_patch vs edit_file). Unlike DebugTelemetry's in-memory event stream,
/// these survive restarts — they exist to answer "does apply_patch earn its
/// keep" with real numbers over days of use.
/// Stored at ~/.local/share/briglia/edit_tool_stats.json
/// as a flat {"apply_patch.success": N, "apply_patch.failure": N, ...} map.
actor EditToolStats {
    static let shared = EditToolStats()

    private var counts: [String: Int] = [:]
    private var loaded = false

    private var fileURL: URL {
        return StoragePaths.dataRoot
            .appendingPathComponent("edit_tool_stats.json")
    }

    func record(tool: String, success: Bool) {
        loadIfNeeded()
        counts["\(tool).\(success ? "success" : "failure")", default: 0] += 1
        save()
    }

    func snapshot() -> [String: Int] {
        loadIfNeeded()
        return counts
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        counts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? PrivateStorage.ensureDirectory(fileURL.deletingLastPathComponent())
        try? PrivateStorage.writeAtomically(data, to: fileURL)
    }

    /// Fire-and-forget from any isolation context.
    nonisolated static func log(tool: String, success: Bool) {
        Task { await EditToolStats.shared.record(tool: tool, success: success) }
    }
}

/// Managed-bash-jobs field observation (BASH_V2_PLAN §15 Phase 5): plain
/// counters persisted to bash_jobs_stats.json, used to decide whether the
/// legacy bash arguments can eventually leave the advertised schema and to
/// spot wait misuse in the field. NEVER records commands, output, workdirs,
/// or any secret-bearing value — counter keys and durations only.
actor BashJobsStats {
    static let shared = BashJobsStats()

    private var counts: [String: Int] = [:]
    private var loaded = false

    private var fileURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("bash_jobs_stats.json")
    }

    func record(_ key: String, by amount: Int = 1) {
        loadIfNeeded()
        counts[key, default: 0] += amount
        save()
    }

    /// Wait durations aggregate as count/total/max so average and maximum
    /// are derivable without per-event storage.
    func recordWaitDuration(ms: Int) {
        loadIfNeeded()
        counts["wait.count", default: 0] += 1
        counts["wait.total_ms", default: 0] += ms
        counts["wait.max_ms"] = max(counts["wait.max_ms"] ?? 0, ms)
        save()
    }

    func snapshot() -> [String: Int] {
        loadIfNeeded()
        return counts
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        counts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        try? PrivateStorage.ensureDirectory(fileURL.deletingLastPathComponent())
        try? PrivateStorage.writeAtomically(data, to: fileURL)
    }

    /// Fire-and-forget from any isolation context.
    nonisolated static func log(_ key: String, by amount: Int = 1) {
        Task { await BashJobsStats.shared.record(key, by: amount) }
    }

    nonisolated static func logWait(ms: Int) {
        Task { await BashJobsStats.shared.recordWaitDuration(ms: ms) }
    }
}
