import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// One event posted to an external-trigger watcher via `briglia trigger`.
struct ExternalTriggerEvent: Codable {
    let watcherId: UUID
    let timestamp: Date
    let payload: String?

    enum CodingKeys: String, CodingKey {
        case watcherId = "watcher_id"
        case timestamp = "ts"
        case payload
    }
}

/// File-based spool connecting the short-lived `briglia trigger` process to the
/// running daemon. Each event is one JSON file written atomically (temp +
/// rename) into `~/.local/share/briglia/trigger-events/`; the daemon's poll loop
/// scans the directory, applies the per-watcher cooldown/batching rules, and
/// deletes files only AFTER the fire message is saved to durable
/// conversation history — so a crash between pickup and delivery re-delivers
/// instead of losing events, and events posted while the daemon is down are
/// simply waiting when it comes back. No sockets, no daemon required to post.
///
/// Filenames carry the addressing: `<millis>_<watcherUUID>_<eventUUID>.json`.
/// The daemon's once-per-second scan therefore needs only a directory
/// listing — event files are decoded exclusively at fire time, so an event
/// storm can never turn the poll loop into a JSON-decoding treadmill.
///
/// Storm bound: at most `maxEventsPerWatcher` files per watcher. Beyond the
/// cap, the event is recorded on a per-watcher SATURATING COUNTER file
/// (`overflow_<watcherUUID>.count`, a single integer) instead of stored —
/// truly bounded disk however long the storm lasts. All counter mutations
/// and the count-then-write cap decision run under an flock(2) on
/// `.spool.lock`, so concurrent `briglia trigger` processes can neither race the
/// cap nor lose counter increments. The counter is decremented (never
/// deleted blind) when its batch is CONFIRMED delivered, so overflow counts
/// share the same crash-redelivery guarantee as event files, and increments
/// landing mid-delivery survive for the next fire.
enum TriggerSpool {
    /// Payload cap applied at intake — an external caller must not be able to
    /// flood the conversation with megabytes through a single event.
    static let payloadMaxChars = 2_000

    /// Spooled-file cap per watcher. Env override is an internal test hook.
    static let maxEventsPerWatcher: Int = {
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_TRIGGER_SPOOL_CAP"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 500
    }()

    /// Ceiling for the overflow counter — beyond this a storm is just "a lot".
    static let overflowSaturation = 1_000_000

    static var directoryURL: URL {
        StoragePaths.dataRoot.appendingPathComponent("trigger-events", isDirectory: true)
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Cross-process lock

    /// Run `body` holding an exclusive flock on the spool's lock file. Both
    /// the `briglia trigger` intake (cap check + write/increment) and the
    /// daemon's counter mutations go through this, making the cap decision
    /// and every read-modify-write of a counter atomic across processes.
    /// Held for microseconds; if the lock file cannot even be opened the
    /// operation proceeds unlocked (degraded beats deadlocked).
    private static func withSpoolLock<T>(_ body: () throws -> T) rethrows -> T {
        try? ensureDirectory()
        let fd = open(directoryURL.appendingPathComponent(".spool.lock").path,
                      O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { return try body() }
        _ = flock(fd, LOCK_EX)
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        return try body()
    }

    // MARK: - Filename addressing

    /// Watcher id encoded in an event filename, or nil for foreign files.
    private static func watcherId(fromFilename name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        let parts = name.dropLast(5).split(separator: "_")
        guard parts.count == 3 else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    /// Watcher id encoded in an overflow-counter filename, or nil.
    private static func watcherId(fromCounterFilename name: String) -> UUID? {
        guard name.hasPrefix("overflow_"), name.hasSuffix(".count") else { return nil }
        return UUID(uuidString: String(name.dropFirst(9).dropLast(6)))
    }

    private static func counterURL(forWatcherId id: UUID) -> URL {
        directoryURL.appendingPathComponent("overflow_\(id.uuidString).count")
    }

    private static func allFilenames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []).sorted()
    }

    /// Event filenames in sorted (≈ arrival) order. Foreign or legacy `.json`
    /// names that don't parse are removed — nothing else will ever consume
    /// them, and leaving them would hide them forever.
    private static func eventFilenames() -> [String] {
        var result: [String] = []
        for name in allFilenames() where name.hasSuffix(".json") {
            if watcherId(fromFilename: name) != nil {
                result.append(name)
            } else {
                try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
            }
        }
        return result
    }

    // MARK: - Intake

    enum WriteResult {
        /// Event stored as its own spool file.
        case spooled(URL)
        /// Per-watcher cap reached: recorded on the overflow counter only.
        case overflowed(pendingCount: Int)
    }

    /// Persist one event. The filename leads with a sortable millisecond
    /// timestamp so directory order approximates arrival order; temp + rename
    /// makes each file appear atomically. Past the per-watcher cap the event
    /// increments the saturating overflow counter instead. The cap check and
    /// the write/increment are one critical section under the spool lock.
    @discardableResult
    static func write(watcherId: UUID, payload: String?) throws -> WriteResult {
        try ensureDirectory()
        return try withSpoolLock {
            let pendingCount = eventFilenames().filter { self.watcherId(fromFilename: $0) == watcherId }.count
            if pendingCount >= maxEventsPerWatcher {
                addToOverflowCounter(forWatcherId: watcherId, delta: 1)
                return .overflowed(pendingCount: pendingCount)
            }

            let trimmed = payload?.trimmingCharacters(in: .whitespacesAndNewlines)
            let capped = (trimmed?.isEmpty == false) ? String(trimmed!.prefix(payloadMaxChars)) : nil
            let event = ExternalTriggerEvent(watcherId: watcherId, timestamp: Date(), payload: capped)
            let data = try makeEncoder().encode(event)
            let millis = Int(Date().timeIntervalSince1970 * 1000)
            let finalURL = directoryURL.appendingPathComponent("\(millis)_\(watcherId.uuidString)_\(UUID().uuidString).json")
            let tempURL = directoryURL.appendingPathComponent(".tmp-\(UUID().uuidString)")
            try data.write(to: tempURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            return .spooled(finalURL)
        }
    }

    /// Adjust a watcher's overflow counter by `delta` (call under the spool
    /// lock). The value saturates at `overflowSaturation`; the file is
    /// removed when the count returns to zero.
    private static func addToOverflowCounter(forWatcherId id: UUID, delta: Int) {
        let url = counterURL(forWatcherId: id)
        let current = (try? String(contentsOf: url, encoding: .utf8)).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? 0
        let next = min(max(current + delta, 0), overflowSaturation)
        if next == 0 {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? Data("\(next)".utf8).write(to: url, options: .atomic)
        }
    }

    // MARK: - Daemon scan / delivery

    /// Watchers that currently have anything pending — spooled event files OR
    /// a nonzero overflow counter. Filename parse only, no file contents are
    /// read for events. Including counter files means a watcher whose every
    /// pending event overflowed (storm during a delivery window) still
    /// surfaces instead of stranding until the next normal event.
    static func watchersWithPendingEvents() -> Set<UUID> {
        var ids = Set<UUID>()
        for name in eventFilenames() {
            if let id = watcherId(fromFilename: name) { ids.insert(id) }
        }
        for name in allFilenames() {
            if let id = watcherId(fromCounterFilename: name) { ids.insert(id) }
        }
        return ids
    }

    /// Decoded events for ONE watcher, in filename (≈ arrival) order. Only
    /// called at fire time. Undecodable files are removed — they can only be
    /// corruption, and leaving them would re-log forever.
    static func pendingEvents(forWatcherId id: UUID) -> [(url: URL, event: ExternalTriggerEvent)] {
        let decoder = makeDecoder()
        var result: [(url: URL, event: ExternalTriggerEvent)] = []
        for name in eventFilenames() where watcherId(fromFilename: name) == id {
            let url = directoryURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let event = try? decoder.decode(ExternalTriggerEvent.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            result.append((url, event))
        }
        return result
    }

    /// All decodable spooled events across watchers (test/diagnostic use).
    static func pendingEvents() -> [(url: URL, event: ExternalTriggerEvent)] {
        watchersWithPendingEvents().sorted { $0.uuidString < $1.uuidString }
            .flatMap { pendingEvents(forWatcherId: $0) }
    }

    /// Current overflow count for a watcher — a non-destructive read. The
    /// counter is only reduced by `confirmOverflowDelivered`, after the fire
    /// message is durably saved.
    static func overflowCount(forWatcherId id: UUID) -> Int {
        (try? String(contentsOf: counterURL(forWatcherId: id), encoding: .utf8)).flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        } ?? 0
    }

    /// Subtract a delivered batch's overflow count from the watcher's
    /// counter. Increments that landed between collection and confirmation
    /// remain and surface with the next fire.
    static func confirmOverflowDelivered(forWatcherId id: UUID, count: Int) {
        guard count > 0 else { return }
        withSpoolLock {
            addToOverflowCounter(forWatcherId: id, delta: -count)
        }
    }

    /// Delete consumed (or orphaned) event files.
    static func remove(_ urls: [URL]) {
        for url in urls where url.path.hasPrefix(directoryURL.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Drop every spooled event and overflow record addressed to one watcher
    /// (watcher deleted, or events orphaned by an unknown id).
    static func removeEvents(forWatcherId id: UUID) {
        let doomed = eventFilenames()
            .filter { watcherId(fromFilename: $0) == id }
            .map { directoryURL.appendingPathComponent($0) }
        remove(doomed)
        try? FileManager.default.removeItem(at: counterURL(forWatcherId: id))
    }

    /// Drop the whole spool (memory reset).
    static func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
