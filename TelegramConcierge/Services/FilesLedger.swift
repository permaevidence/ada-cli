import Foundation

/// The ledger records every file the agent has written, generated, or received.
/// It is the source of truth for `list_recent_files` — a memory-backed view of the working set
/// across the whole filesystem, independent of where the files actually live on disk.
///
/// Reads are NOT tracked (by design — prevents bloat during debug sessions that re-read the same file).
/// Only writes and inbound-file events update the ledger.
actor FilesLedger {
    static let shared = FilesLedger()

    enum Origin: String, Codable, CaseIterable {
        case edited      // modified by write_file / edit_file / apply_patch on a pre-existing file
        case generated   // created by write_file / apply_patch / image gen
        case telegram    // incoming Telegram attachment
        case email       // email attachment download
        case download    // URL download
    }

    struct Entry: Codable, Equatable {
        var path: String
        var description: String?
        var last_touched: Date
        var origin: Origin
        var touch_count: Int
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false

    private static let ledgerURL: URL = {
        let folder = StoragePaths.dataRoot
        try? PrivateStorage.ensureDirectory(folder)
        return folder.appendingPathComponent("files_ledger.json")
    }()

    private init() {}

    // MARK: - Public API

    /// Record a write/touch. Merges with any existing entry for the same path,
    /// incrementing touch_count and refreshing last_touched.
    func record(path: String, origin: Origin, description: String? = nil) {
        loadIfNeeded()
        let now = Date()
        if var existing = entries[path] {
            existing.last_touched = now
            existing.touch_count += 1
            if let description, !description.isEmpty {
                existing.description = description
            }
            // Origin update policy:
            //  - Inbound origins (.telegram / .email / .download) are sticky. They
            //    record how the file ENTERED our system and shouldn't be overwritten
            //    by a later edit.
            //  - Write-type origins (.edited / .generated) reflect the MOST RECENT
            //    agent action on the file. A file first generated and later modified
            //    should now show as .edited so the per-turn diff buckets it under
            //    "Edited files" rather than "Generated files".
            switch existing.origin {
            case .telegram, .email, .download:
                break  // inbound provenance sticks
            case .edited, .generated:
                existing.origin = origin
            }
            entries[path] = existing
        } else {
            entries[path] = Entry(
                path: path,
                description: description,
                last_touched: now,
                origin: origin,
                touch_count: 1
            )
        }
        save()
    }

    /// Return entries sorted by last_touched descending, paginated.
    func recentFiles(limit: Int = 20, offset: Int = 0, filterOrigin: Origin? = nil) -> [Entry] {
        loadIfNeeded()
        let filtered = entries.values.filter { entry in
            if let filterOrigin, entry.origin != filterOrigin { return false }
            return true
        }
        let sorted = filtered.sorted { $0.last_touched > $1.last_touched }
        let start = min(max(offset, 0), sorted.count)
        let end = min(start + max(limit, 0), sorted.count)
        return Array(sorted[start..<end])
    }

    /// Total number of entries (used for pagination UI).
    func totalCount(filterOrigin: Origin? = nil) -> Int {
        loadIfNeeded()
        if let filterOrigin {
            return entries.values.filter { $0.origin == filterOrigin }.count
        }
        return entries.count
    }

    /// Remove an entry (e.g. after a file is deleted from disk).
    func remove(path: String) {
        loadIfNeeded()
        if entries.removeValue(forKey: path) != nil {
            save()
        }
    }

    /// Wipe the entire ledger (in-memory and on-disk). Used by Settings ▸ Delete Memory.
    func clearAll() {
        loadIfNeeded()
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.ledgerURL)
    }

    /// Reload ledger entries after a Mind restore replaces the backing JSON file.
    func reloadFromDisk() {
        entries.removeAll()
        loaded = false
        loadIfNeeded()
    }

    // MARK: - Persistence

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.ledgerURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([Entry].self, from: data) {
            for entry in decoded {
                entries[entry.path] = entry
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = entries.values.sorted { $0.last_touched > $1.last_touched }
        guard let data = try? encoder.encode(sorted) else { return }
        // Atomic write: exclusive temp in the same directory, then rename.
        do {
            try PrivateStorage.writeAtomically(data, to: Self.ledgerURL)
        } catch {
            print("[FilesLedger] save failed: \(error)")
        }
    }
}
