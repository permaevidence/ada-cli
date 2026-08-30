import Foundation

/// Watches `LandingZone.scratchReposRoot` for disk pressure. Does NOT delete anything
/// itself — when the dir crosses `thresholdBytes`, it asks `ConversationManager` to
/// inject a cleanup prompt so the agent (which knows what's still active work) picks
/// which clones to remove.
///
/// Rationale: a blind TTL sweep could kill a clone the user is still actively
/// exploring; delegating the decision to the agent preserves ongoing work and keeps
/// the system prompt's "rm -rf when done" rule as the primary cleanup path.
enum ScratchDiskMonitor {

    /// Prompt the agent when the scratch dir exceeds this size.
    static let thresholdBytes: Int64 = 15 * 1024 * 1024 * 1024   // 15 GB

    /// Minimum time between successive pressure prompts. Prevents nag loops if the
    /// agent declines to delete anything (e.g. all clones are still active work).
    static let minInterPromptInterval: TimeInterval = 6 * 60 * 60 // 6h

    /// How many entries to surface in the cleanup prompt. The dir is listed by
    /// mtime ascending (stalest first), so the agent sees the best candidates.
    static let maxEntriesInPrompt = 30

    struct Entry {
        let path: String
        let name: String
        let sizeBytes: Int64
        let mtime: Date
    }

    struct Measurement {
        let totalBytes: Int64
        let entries: [Entry]  // stalest first (oldest mtime first)
    }

    // MARK: - Measurement

    /// Walk the top-level entries of `scratchReposRoot` and compute size per entry
    /// plus total. "Top-level" = each direct child of the scratch dir is treated as
    /// a single unit (matches how clones are organised — one dir per clone).
    static func measure() -> Measurement {
        let fm = FileManager.default
        let root = LandingZone.scratchReposRoot
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Measurement(totalBytes: 0, entries: [])
        }

        var entries: [Entry] = []
        var total: Int64 = 0
        for url in children {
            let size = directorySize(at: url)
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = rv?.contentModificationDate ?? .distantPast
            entries.append(Entry(
                path: url.path,
                name: url.lastPathComponent,
                sizeBytes: size,
                mtime: mtime
            ))
            total += size
        }
        entries.sort { $0.mtime < $1.mtime }  // stalest first
        return Measurement(totalBytes: total, entries: entries)
    }

    private static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(rv?.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let rv = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if rv?.isRegularFile == true, let size = rv?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Cooldown state (actor-isolated)

    private static let stateLock = NSLock()
    private static var lastPromptedAt: Date?

    /// True if we are over the threshold AND the cooldown has elapsed since the
    /// last time we nagged. Also stamps the current time so callers don't need a
    /// second trip — the stamp commits immediately on a green return.
    static func shouldPromptNow(measurement: Measurement) -> Bool {
        guard measurement.totalBytes > thresholdBytes else { return false }
        stateLock.lock(); defer { stateLock.unlock() }
        if let last = lastPromptedAt, Date().timeIntervalSince(last) < minInterPromptInterval {
            return false
        }
        lastPromptedAt = Date()
        return true
    }

    // MARK: - Prompt formatting

    /// Human-readable cleanup prompt injected as a reminder-kind message.
    /// The agent is expected to inspect the listing, pick the stalest ones that
    /// aren't part of active work, and run `bash rm -rf <path>` on them.
    static func formatCleanupPrompt(from measurement: Measurement) -> String {
        let totalGB = String(format: "%.2f", Double(measurement.totalBytes) / 1_073_741_824)
        let thresholdGB = String(format: "%.0f", Double(thresholdBytes) / 1_073_741_824)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("[SCRATCH DISK PRESSURE — agent self-prompt]")
        lines.append("")
        lines.append("The scratch dir at \(LandingZone.scratchReposRoot.path) is now \(totalGB) GB (threshold \(thresholdGB) GB).")
        lines.append("Entries below are sorted stalest first. Delete the ones that are no longer part of active work.")
        lines.append("")
        lines.append("Candidates (stalest first, up to \(maxEntriesInPrompt)):")

        let shown = measurement.entries.prefix(maxEntriesInPrompt)
        for e in shown {
            let sizeMB = String(format: "%.1f", Double(e.sizeBytes) / 1_048_576)
            let mtimeStr = isoFormatter.string(from: e.mtime)
            lines.append("  • \(e.path)  — \(sizeMB) MB, mtime \(mtimeStr)")
        }
        if measurement.entries.count > maxEntriesInPrompt {
            lines.append("  … plus \(measurement.entries.count - maxEntriesInPrompt) more")
        }
        lines.append("")
        lines.append("Action: for each clone you judge safe to remove, run `bash rm -rf <path>`. If every clone is still relevant to ongoing work, reply [SKIP] — the monitor will back off for \(Int(minInterPromptInterval / 3600))h before nagging again.")
        lines.append("")
        lines.append("[END OF SELF-PROMPT]")
        return lines.joined(separator: "\n")
    }
}
