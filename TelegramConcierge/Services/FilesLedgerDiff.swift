import Foundation

/// Snapshot + diff utility over `FilesLedger`.
///
/// Used by both `SubagentRunner` (to report `filesTouched`) and `ConversationManager`
/// (to surface per-turn edited/generated paths onto the resulting assistant `Message`).
///
/// Rationale: `FilesLedger.shared.record(...)` already happens at every write site
/// (write_file, edit_file, apply_patch, image gen, inbound downloads). Taking a
/// pre-/post-snapshot around a turn is the cheapest way to observe what was touched
/// without threading new parameters through every tool path.
enum FilesLedgerDiff {

    struct Snapshot {
        let byPath: [String: (lastTouched: Date, touchCount: Int, origin: FilesLedger.Origin)]
    }

    /// Capture the current ledger state. FilesLedger is an in-memory actor so this is cheap.
    static func snapshot() async -> Snapshot {
        // Request a generous page; FilesLedger is in-memory so this is cheap.
        let entries = await FilesLedger.shared.recentFiles(limit: 100_000, offset: 0, filterOrigin: nil)
        var map: [String: (Date, Int, FilesLedger.Origin)] = [:]
        for e in entries { map[e.path] = (e.last_touched, e.touch_count, e.origin) }
        return Snapshot(byPath: map.mapValues {
            (lastTouched: $0.0, touchCount: $0.1, origin: $0.2)
        })
    }

    struct Changed {
        /// Absolute paths (sorted) of pre-existing files modified during the window.
        let edited: [String]
        /// Absolute paths (sorted) of newly-created files during the window.
        let generated: [String]

        /// Combined sorted list — used by SubagentRunner.Result.filesTouched (flat).
        var allTouched: [String] {
            var combined = Set(edited)
            for g in generated { combined.insert(g) }
            return Array(combined).sorted()
        }
    }

    /// Returns the files that were added or bumped (touchCount increased OR lastTouched
    /// advanced) between `pre` and `post`, split by their current origin in `post`.
    ///
    /// We only classify origins `.edited` and `.generated` here — inbound origins
    /// (telegram / email / download) are not surfaced as "files the agent produced".
    static func diff(pre: Snapshot, post: Snapshot) -> Changed {
        var edited: [String] = []
        var generated: [String] = []
        for (path, postVal) in post.byPath {
            let bumped: Bool
            if let preVal = pre.byPath[path] {
                bumped = postVal.touchCount > preVal.touchCount || postVal.lastTouched > preVal.lastTouched
            } else {
                bumped = true
            }
            guard bumped else { continue }
            switch postVal.origin {
            case .edited:    edited.append(path)
            case .generated: generated.append(path)
            case .telegram, .email, .download:
                // Inbound origins are surfaced via other mechanisms (downloadedDocumentFileNames).
                continue
            }
        }
        edited.sort()
        generated.sort()
        return Changed(edited: edited, generated: generated)
    }
}
