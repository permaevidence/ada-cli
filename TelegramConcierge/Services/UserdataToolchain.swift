import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
/// syncfs(2) is a glibc wrapper (since 2.14) that Swift's Glibc module
/// doesn't surface — bind the libc symbol directly. Flushes the whole
/// filesystem containing fd; returns 0 or -1 with errno.
@_silgen_name("syncfs")
private func ada_syncfs(_ fd: Int32) -> Int32
#endif

/// Installs Briglia's optional media/document tools into a USERDATA prefix —
/// built for Ubuntu Touch, where the root filesystem is ~3 GB, normally
/// read-only, easily filled, and replaced wholesale by OTA updates (which
/// silently deletes anything apt ever installed there, while Briglia itself
/// survives on userdata).
///
/// Mechanism (proven on-device, Pixel POC rounds 1–3, 2026-08-28):
///   1. apt update with Dir::State/Dir::Cache redirected under the prefix —
///      the package lists (~220 MB) land on userdata, never on the rootfs
///   2. apt install --download-only resolves the dependency closure against
///      a SYNTHETIC dpkg status that only admits the guaranteed base system
///      (Essential + required + the libc family, dependency-closed), so the
///      COMPLETE closure downloads regardless of what the rootfs holds.
///      Field lesson: resolving against the real status made prefixes lean
///      on system library copies, and a later purge broke a working prefix
///      within hours — an OTA can do the same. Only packages the OS cannot
///      exist without are ever taken from the system.
///   3. dpkg -x extracts each .deb into the prefix (no root, no dpkg db);
///      the libc family is never extracted — mixing a foreign libc with
///      the system's ld.so is a crash, not an install
///   4. PATH wrappers export LD_LIBRARY_PATH (and ImageMagick's module/
///      config paths) and exec the prefixed binary. ImageMagick's plain
///      names (convert/identify/…) are alternatives symlinks created by a
///      postinst that dpkg -x never runs, so wrappers fall back to the
///      real convert-im6.q16-style names. LibreOffice needs more: its rc
///      files hardcode /usr/lib/libreoffice and /etc/libreoffice/registry,
///      and its private libs live in program/ — see relocateLibreOffice().
///   5. every wrapper is verified with a version probe; a wrapper that
///      fails its probe is removed rather than left shadowing PATH.
///      Wrappers carry a closure marker — pre-self-contained (v1) wrappers
///      found on a later run trigger a full prefix rebuild.
///
/// All commands and lookup paths are injectable via BRIGLIA_TOOLCHAIN_* env
/// seams so the selftest can run hermetically on any platform.
enum UserdataToolchain {

    struct PackageSpec {
        let key: String      // stable component id, shown as the group label
        let apt: [String]
        let tools: [String]
        let optional: Bool   // pandoc/libreoffice-class: only on request
    }

    static let packages: [PackageSpec] = [
        PackageSpec(key: "poppler-utils", apt: ["poppler-utils"],
                    tools: ["pdftotext", "pdftoppm", "pdfinfo",
                            "pdfseparate", "pdfunite"], optional: false),
        PackageSpec(key: "imagemagick", apt: ["imagemagick"],
                    tools: ["convert", "identify", "mogrify"], optional: false),
        PackageSpec(key: "ffmpeg", apt: ["ffmpeg"],
                    tools: ["ffmpeg", "ffprobe"], optional: false),
        PackageSpec(key: "pandoc", apt: ["pandoc"], tools: ["pandoc"],
                    optional: true),
        // Headless conversions only (docx/xlsx/pptx → PDF and friends) —
        // the -nogui variants skip the entire GUI stack. Falls back to the
        // full packages on images without the nogui split.
        PackageSpec(key: "libreoffice",
                    apt: ["libreoffice-writer-nogui", "libreoffice-calc-nogui",
                          "libreoffice-impress-nogui"],
                    tools: ["soffice", "libreoffice"], optional: true),
    ]

    static let wrapperMarker = "# briglia-userdata-toolchain wrapper"
    /// Marker written by the previous product identity. Accepted forever:
    /// wrappers migrated by `briglia migrate` keep it (only their embedded
    /// prefix path is rebased) until the next toolchain operation rewrites
    /// them (rename plan §4.5.9).
    static let legacyWrapperMarker = "# ada-userdata-toolchain wrapper"
    static var acceptedWrapperMarkers: [String] { [wrapperMarker, legacyWrapperMarker] }
    /// Wrappers whose prefix bundles the full dependency closure. Absence
    /// marks a v1 wrapper that leans on system libraries → rebuild.
    static let closureMarker = "# ada-toolchain-closure: self-contained"

    /// Version-probe arguments per tool (all exit 0 on the real tools).
    static let probeArgs: [String: [String]] = [
        "pdftotext": ["-v"], "pdftoppm": ["-v"], "pdfinfo": ["-v"],
        "pdfseparate": ["-v"], "pdfunite": ["-v"],
        "convert": ["-version"], "identify": ["-version"],
        "mogrify": ["-version"],
        "ffmpeg": ["-version"], "ffprobe": ["-version"],
        "pandoc": ["--version"],
        "soffice": ["--version"], "libreoffice": ["--version"],
    ]

    // ------------------------------------------------------------ paths

    static var root: URL {
        if let env = ProcessInfo.processInfo.environment["BRIGLIA_TOOLCHAIN_ROOT"] {
            return URL(fileURLWithPath: env)
        }
        return StoragePaths.dataRoot.appendingPathComponent("toolchain")
    }

    static var prefixDir: URL { root.appendingPathComponent("prefix") }
    /// Where a transactional rebuild constructs the NEW prefix. The working
    /// prefix stays live and untouched at prefixDir for the entire apt/
    /// extract/validate phase — a running daemon never sees a half-built
    /// toolchain (Codex round 3 #1). Only after full validation does a
    /// rename swap prefix.new into place.
    static var stagingDir: URL { root.appendingPathComponent("prefix.new") }
    /// Where the working prefix moves during the brief commit swap. While
    /// tx/state says "prepared", the backup is the verified old state; once
    /// it says "committed", the live prefix is authoritative and any
    /// leftover backup (possibly partially deleted) is only cleanup debt.
    static var backupDir: URL { root.appendingPathComponent("prefix.previous") }
    /// Transaction snapshot persisted BEFORE a rebuild changes anything
    /// visible: tx/wrappers/<tool> (pre-rebuild wrapper scripts),
    /// tx/manifest.json, and tx/state ("prepared" | "committed"). The
    /// snapshot directory appears atomically (built as tx.tmp-*, renamed
    /// into place), so its existence implies it is complete. Crash recovery
    /// needs all three pieces — restoring only the prefix would leave
    /// wrappers/manifest from the interrupted run claiming versions the
    /// restored binaries don't have.
    static var txDir: URL { root.appendingPathComponent("tx") }
    static var txStateURL: URL { txDir.appendingPathComponent("state") }
    static var aptDir: URL { root.appendingPathComponent("apt") }

    static func txState() -> String? {
        (try? String(contentsOf: txStateURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fault-injection seam for durability tests (same pattern as
    /// BRIGLIA_UPGRADE_FAULT): "snapshot-flush" | "commit-flush".
    private static var faultPoint: String? {
        ProcessInfo.processInfo.environment["BRIGLIA_TOOLCHAIN_FAULT"]
    }

    /// Checked fsync of one existing file or directory. Returns nil on
    /// success, else a one-line reason — a failed flush must surface, never
    /// be shrugged off (Codex round 4: ignored open/fsync results let a
    /// durable-looking marker certify state still in volatile caches).
    static func fsyncPath(_ url: URL) -> String? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            return "could not open \(url.path) for fsync: \(String(cString: strerror(errno)))"
        }
        let rc = fsync(fd)
        close(fd)
        guard rc == 0 else {
            return "fsync failed for \(url.path): \(String(cString: strerror(errno)))"
        }
        return nil
    }

    /// Storage barrier: everything previously written under the given
    /// locations must reach stable storage before this returns nil. On
    /// Linux (the only platform where the userdata toolchain runs for
    /// real — macOS reaches this code solely through the hermetic
    /// selftest) syncfs(2) flushes each location's whole filesystem, which
    /// covers the thousands of extracted prefix files, the swap renames,
    /// wrappers and manifest in one checked call per filesystem.
    static func flushStorage(_ urls: [URL]) -> String? {
        if faultPoint == "commit-flush" {
            return "injected commit-flush fault"
        }
        #if os(Linux)
        for url in urls {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else {
                return "could not open \(url.path) for syncfs: \(String(cString: strerror(errno)))"
            }
            let rc = ada_syncfs(fd)
            close(fd)
            guard rc == 0 else {
                return "syncfs failed for \(url.path): \(String(cString: strerror(errno)))"
            }
        }
        #else
        Darwin.sync()
        _ = urls
        #endif
        return nil
    }

    /// Durable small-file write: temp + CHECKED fsync + rename(2) + CHECKED
    /// directory fsync. The commit marker rides on this — once it returns
    /// nil the content survives power loss. Returns nil on success, else a
    /// one-line reason.
    @discardableResult
    static func writeDurable(_ data: Data, to url: URL) -> String? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return "could not create \(dir.path): \(error.localizedDescription)"
        }
        let tmp = dir.appendingPathComponent(".durable-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
        } catch {
            return "could not write \(tmp.path): \(error.localizedDescription)"
        }
        if let why = fsyncPath(tmp) {
            try? fm.removeItem(at: tmp)
            return why
        }
        guard rename(tmp.path, url.path) == 0 else {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            return "could not move \(tmp.lastPathComponent) into place: \(why)"
        }
        if let why = fsyncPath(dir) { return why }
        return nil
    }

    @discardableResult
    static func writeDurable(_ text: String, to url: URL) -> String? {
        writeDurable(Data(text.utf8), to: url)
    }

    /// Where wrappers go — must be on Briglia's PATH; ~/.local/bin is where the
    /// installer already puts `briglia` itself.
    static var wrapperBinDir: URL {
        if let env = ProcessInfo.processInfo.environment["BRIGLIA_TOOLCHAIN_BIN"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin")
    }

    static var dpkgStatusPath: String {
        ProcessInfo.processInfo.environment["BRIGLIA_TOOLCHAIN_DPKG_STATUS"]
            ?? "/var/lib/dpkg/status"
    }

    private static func externalTool(_ envKey: String, _ name: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[envKey] { return env }
        return findTool(name)
    }

    /// Tool presence lookup. BRIGLIA_TOOLCHAIN_PATH (colon-separated dirs)
    /// restricts the search for hermetic tests; otherwise the normal
    /// PATH + standard prefixes rules apply.
    static func findTool(_ name: String) -> String? {
        if let scoped = ProcessInfo.processInfo.environment["BRIGLIA_TOOLCHAIN_PATH"] {
            for dir in scoped.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return nil
        }
        return PlatformBinary.find(name)
    }

    // ----------------------------------------------------------- status

    struct ToolStatus {
        let name: String
        let package: String
        let present: Bool
        /// "system" | "prefix" | "missing"
        let source: String
        let optional: Bool
    }

    static func status(includeOptional: Bool = true) -> [ToolStatus] {
        var out: [ToolStatus] = []
        for spec in packages where includeOptional || !spec.optional {
            for tool in spec.tools {
                guard let path = findTool(tool) else {
                    out.append(ToolStatus(name: tool, package: spec.key,
                                          present: false, source: "missing",
                                          optional: spec.optional))
                    continue
                }
                let source = isOurWrapper(path) ? "prefix" : "system"
                out.append(ToolStatus(name: tool, package: spec.key,
                                      present: true, source: source,
                                      optional: spec.optional))
            }
        }
        return out
    }

    static func isOurWrapper(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 256)
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return acceptedWrapperMarkers.contains { text.contains($0) }
    }

    // ---------------------------------------------------------- install

    struct InstallReport {
        var installedPackages: [String] = []
        var alreadyPresent: [String] = []
        var wrappers: [String] = []
        var failures: [String] = []
        var notes: [String] = []
        var ok: Bool { failures.isEmpty }
    }

    /// Cross-process mutual exclusion for install/upgrade/remove: two
    /// concurrent operations would interpret each other's LIVE transaction
    /// as a crashed one — the second would "recover" the first's set-aside
    /// prefix mid-rebuild, destroying its staging. flock on a stable
    /// sidecar; fail fast rather than queue (apt runs for minutes — the
    /// caller surfaces the busy message and the user retries).
    private static func acquireLock() -> (fd: Int32?, failure: String?) {
        // The lock lives BESIDE the toolchain root, never inside it:
        // removeAll deletes the root wholesale, and unlinking a held lock
        // file would let a concurrent process recreate the path as a NEW
        // inode and "acquire" it while removal still runs on the old one
        // (Codex round 3 #3).
        try? PrivateStorage.ensureDirectoryScoped(root.deletingLastPathComponent())
        let path = root.path + ".lock"
        let fd = open(path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else {
            return (nil, "could not open the toolchain lock at \(path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return (nil, "another toolchain operation is already running — wait for it to finish and retry")
        }
        return (fd, nil)
    }

    /// Synchronous by design (call off the main actor): apt runs for
    /// minutes on phone-grade networks. `forceRebuild` treats every
    /// prefix-installed tool as needing reinstall — the upgrade path.
    static func installSync(includePandoc: Bool,
                            includeLibreOffice: Bool = false,
                            forceRebuild: Bool = false,
                            progress: (String) -> Void) -> InstallReport {
        let lock = acquireLock()
        guard let fd = lock.fd else {
            var report = InstallReport()
            report.failures.append(lock.failure ?? "could not acquire the toolchain lock")
            return report
        }
        defer { flock(fd, LOCK_UN); close(fd) }
        return installSyncLocked(includePandoc: includePandoc,
                                 includeLibreOffice: includeLibreOffice,
                                 forceRebuild: forceRebuild,
                                 progress: progress)
    }

    /// Crash recovery for interrupted transactional rebuilds. Requires the
    /// toolchain lock. Appends notes to `report`; returns a fatal failure
    /// message, or nil when the on-disk state is consistent.
    ///
    /// The tx/state file decides authority (Codex round 3 #1 — the old code
    /// used "backup still exists" as the uncommitted signal, but backup
    /// deletion is a long recursive operation: a crash mid-deletion left a
    /// PARTIAL backup that recovery then restored over the complete new
    /// prefix):
    ///   • "committed": the live prefix/wrappers/manifest are authoritative.
    ///     Leftover backup contents — whole or partial — are cleanup debt,
    ///     never restored. Trusting the marker unconditionally is sound
    ///     because commitRebuild runs a checked storage barrier
    ///     (flushStorage) over every filesystem involved BEFORE writing it:
    ///     a durable marker implies the state it certifies is durable too.
    ///   • "prepared" (or unreadable): the tx snapshot is the authoritative
    ///     OLD state; disk may hold any mix of old and new pieces. Converge
    ///     everything back with CHECKED writes, and keep the snapshot unless
    ///     every restore succeeded — a failed recovery write must never
    ///     discard its only good copy.
    static func recoverInterrupted(_ report: inout InstallReport) -> String? {
        let fm = FileManager.default
        let txWrappersDir = txDir.appendingPathComponent("wrappers")
        let txManifest = txDir.appendingPathComponent("manifest.json")

        if fm.fileExists(atPath: txDir.path) {
            if txState() == "committed" {
                if fm.fileExists(atPath: backupDir.path) {
                    do {
                        try fm.removeItem(at: backupDir)
                    } catch {
                        return "a committed toolchain rebuild left a backup that cannot be cleaned up (\(backupDir.path)): \(error.localizedDescription) — the installed toolchain is intact; free the path and re-run"
                    }
                }
                try? fm.removeItem(at: stagingDir)
                try? fm.removeItem(at: txDir)
                report.notes.append("finished cleaning up an interrupted rebuild that had already committed")
                return nil
            }
            // Uncommitted. Restore in an order that keeps the snapshot and
            // backup valid for retry at every possible failure point.
            if fm.fileExists(atPath: backupDir.path) {
                // Crash during/after the swap: whatever sits at prefixDir is
                // unverified staging output (or nothing).
                if fm.fileExists(atPath: prefixDir.path) {
                    do { try fm.removeItem(at: prefixDir) } catch {
                        return "recovery could not discard the unverified prefix at \(prefixDir.path): \(error.localizedDescription) — the backup and snapshot are preserved; free the path and re-run"
                    }
                }
                do { try fm.moveItem(at: backupDir, to: prefixDir) } catch {
                    return "recovery could not restore the previous prefix from \(backupDir.path): \(error.localizedDescription) — the backup and snapshot are preserved"
                }
            }
            if fm.fileExists(atPath: txWrappersDir.path) {
                let snapshot = Set((try? fm.contentsOfDirectory(atPath: txWrappersDir.path)) ?? [])
                for spec in packages {
                    for tool in spec.tools {
                        let wrapper = wrapperBinDir.appendingPathComponent(tool)
                        if snapshot.contains(tool) {
                            do {
                                let text = try String(
                                    contentsOf: txWrappersDir.appendingPathComponent(tool),
                                    encoding: .utf8)
                                try text.write(to: wrapper, atomically: true, encoding: .utf8)
                                try fm.setAttributes([.posixPermissions: 0o755],
                                                     ofItemAtPath: wrapper.path)
                            } catch {
                                return "recovery could not restore the \(tool) wrapper: \(error.localizedDescription) — the snapshot at \(txDir.path) is preserved; re-run to retry"
                            }
                        } else if fm.fileExists(atPath: wrapper.path),
                                  isOurWrapper(wrapper.path) {
                            // Ours but absent from the snapshot: written by
                            // the interrupted run, points at discarded staging.
                            do { try fm.removeItem(at: wrapper) } catch {
                                return "recovery could not remove the interrupted run's \(tool) wrapper: \(error.localizedDescription) — the snapshot at \(txDir.path) is preserved; re-run to retry"
                            }
                        }
                    }
                }
            }
            if let data = try? Data(contentsOf: txManifest),
               let map = try? JSONDecoder().decode([String: String].self, from: data),
               let why = saveManifestChecked(map) {
                return "recovery could not restore the version manifest: \(why) — the snapshot at \(txDir.path) is preserved; re-run to retry"
            }
            try? fm.removeItem(at: stagingDir)
            do { try fm.removeItem(at: txDir) } catch {
                // Harmless: the next run re-converges idempotently.
                report.notes.append("recovered, but the transaction snapshot could not be deleted (\(error.localizedDescription)) — the next run re-verifies")
            }
            report.notes.append("recovered the previous toolchain after an interrupted rebuild")
        } else if fm.fileExists(atPath: backupDir.path) {
            // Pre-state-file layout (older Briglia version, or manual meddling):
            // no snapshot to consult — the old rule applies, the backup is
            // the last verified state.
            try? fm.removeItem(at: prefixDir)
            do { try fm.moveItem(at: backupDir, to: prefixDir) } catch {
                return "found an interrupted rebuild but could not restore the previous prefix from \(backupDir.path): \(error.localizedDescription)"
            }
            report.notes.append("recovered the previous toolchain after an interrupted rebuild")
        } else if fm.fileExists(atPath: stagingDir.path) {
            // Stale staging from a crashed non-transactional build.
            try? fm.removeItem(at: stagingDir)
        }
        return nil
    }

    /// The body, callable only while holding the toolchain lock (installSync
    /// and upgradeSync acquire it — flock is per open file description, so
    /// re-acquiring here would deadlock the upgrade's internal rebuild).
    private static func installSyncLocked(includePandoc: Bool,
                                          includeLibreOffice: Bool = false,
                                          forceRebuild: Bool = false,
                                          progress: (String) -> Void) -> InstallReport {
        var report = InstallReport()
        let fm = FileManager.default

        if let failure = recoverInterrupted(&report) {
            report.failures.append(failure)
            return report
        }

        func requested(_ spec: PackageSpec) -> Bool {
            switch spec.key {
            case "pandoc": return includePandoc
            case "libreoffice": return includeLibreOffice
            default: return true
            }
        }
        func ourWrapperPath(_ tool: String) -> String? {
            guard let path = findTool(tool), isOurWrapper(path) else { return nil }
            return path
        }
        func isSelfContained(_ path: String) -> Bool {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { return false }
            return text.contains(closureMarker)
        }
        func probePasses(_ tool: String, at path: String) -> Bool {
            probeTool(tool, at: path).exitCode == 0
        }

        // What does each component need? A tool needs (re)installing when it
        // is missing (and its component was requested), or when our wrapper
        // exists but is v1 (pre-self-contained) or fails its probe — the
        // probe re-check is what heals a prefix a later purge/OTA broke.
        var needed: [String: [String]] = [:]
        var rebuildPrefix = false
        for spec in packages {
            var tools: [String] = []
            var hasOurs = false
            for tool in spec.tools {
                if let path = ourWrapperPath(tool) {
                    hasOurs = true
                    if forceRebuild || !isSelfContained(path) {
                        tools.append(tool)
                        rebuildPrefix = true
                    } else if !probePasses(tool, at: path) {
                        tools.append(tool)
                    }
                } else if findTool(tool) == nil, requested(spec) {
                    tools.append(tool)
                }
            }
            if !tools.isEmpty {
                needed[spec.key] = tools
            } else if requested(spec) || hasOurs {
                report.alreadyPresent.append(spec.key)
            }
        }

        // A prefix rebuild replaces the shared prefix directory, so every
        // component with tools living there must reinstall in the same run —
        // including optional ones the caller didn't ask for this time.
        var wrapperRollback: [String: String] = [:]
        var manifestRollback: [String: String] = [:]
        var transactionActive = false
        if rebuildPrefix {
            progress("rebuilding the prefix with self-contained dependency closures…")
            for spec in packages {
                var tools = needed[spec.key] ?? []
                for tool in spec.tools
                    where ourWrapperPath(tool) != nil && !tools.contains(tool) {
                    tools.append(tool)
                }
                if !tools.isEmpty { needed[spec.key] = tools }
            }
            report.alreadyPresent.removeAll { needed[$0] != nil }
            // Transactional: the new prefix is BUILT at prefix.new while the
            // working prefix keeps serving at prefixDir — a rebuild that
            // fails at any step (network, repo, disk, extraction, probes)
            // leaves the toolchain that worked this morning completely
            // untouched, and a running daemon never sees a half-built
            // prefix. Wrapper scripts and the version manifest are
            // snapshotted so the brief commit swap can also roll back.
            for spec in packages {
                for tool in spec.tools {
                    if let path = ourWrapperPath(tool),
                       let text = try? String(contentsOfFile: path, encoding: .utf8) {
                        wrapperRollback[tool] = text
                    }
                }
            }
            manifestRollback = loadManifest()
            try? fm.removeItem(at: stagingDir)
            if fm.fileExists(atPath: prefixDir.path) {
                // Persist the snapshot BEFORE anything else: built privately
                // as tx.tmp-*, then renamed into place, so tx/ can never
                // exist half-written — recovery treats its presence as "the
                // complete authoritative old state". A crash right here
                // leaves the live toolchain untouched.
                let txTmp = root.appendingPathComponent("tx.tmp-\(UUID().uuidString)")
                do {
                    try? fm.removeItem(at: txDir)
                    try fm.createDirectory(at: txTmp.appendingPathComponent("wrappers"),
                                           withIntermediateDirectories: true)
                    for (tool, text) in wrapperRollback {
                        try text.write(
                            to: txTmp.appendingPathComponent("wrappers/\(tool)"),
                            atomically: true, encoding: .utf8)
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(manifestRollback)
                        .write(to: txTmp.appendingPathComponent("manifest.json"),
                               options: .atomic)
                    if let why = writeDurable("prepared",
                                              to: txTmp.appendingPathComponent("state")) {
                        throw NSError(domain: "AdaToolchain", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: why])
                    }
                    // Every snapshot byte must be on disk BEFORE tx/
                    // appears: recovery treats its presence as a complete,
                    // durable copy of the old state — an unflushed snapshot
                    // could restore garbage after power loss (Codex rnd 4).
                    if faultPoint == "snapshot-flush" {
                        throw NSError(domain: "AdaToolchain", code: 3, userInfo: [
                            NSLocalizedDescriptionKey: "injected snapshot-flush fault"])
                    }
                    var toFlush = wrapperRollback.keys.map {
                        txTmp.appendingPathComponent("wrappers/\($0)")
                    }
                    toFlush += [txTmp.appendingPathComponent("manifest.json"),
                                txTmp.appendingPathComponent("wrappers"), txTmp]
                    for url in toFlush {
                        if let why = fsyncPath(url) {
                            throw NSError(domain: "AdaToolchain", code: 4, userInfo: [
                                NSLocalizedDescriptionKey: "snapshot flush: \(why)"])
                        }
                    }
                    guard rename(txTmp.path, txDir.path) == 0 else {
                        throw NSError(domain: "AdaToolchain", code: 2, userInfo: [
                            NSLocalizedDescriptionKey:
                                "rename to tx/: \(String(cString: strerror(errno)))"])
                    }
                    if let why = fsyncPath(root) {
                        throw NSError(domain: "AdaToolchain", code: 5, userInfo: [
                            NSLocalizedDescriptionKey: "snapshot flush: \(why)"])
                    }
                } catch {
                    try? fm.removeItem(at: txTmp)
                    try? fm.removeItem(at: txDir)
                    report.failures.append("could not persist the rebuild's rollback snapshot: \(error.localizedDescription)")
                    return report
                }
                transactionActive = true
            }
        }

        // During a rebuild everything is constructed/validated against the
        // staging area; probe wrappers live inside it so the REAL wrappers
        // on PATH stay untouched until the commit swap.
        let buildRoot = rebuildPrefix ? stagingDir : prefixDir
        let probeBinDir = rebuildPrefix
            ? stagingDir.appendingPathComponent(".ada-probe-bin")
            : wrapperBinDir

        // Build-phase failures during a rebuild leave the working toolchain
        // completely untouched — staging and the snapshot are just discarded.
        // (Incremental installs pass through unchanged, as before.)
        func abortBuild(_ r: InstallReport) -> InstallReport {
            var r = r
            guard rebuildPrefix else { return r }
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: txDir)
            if transactionActive && !r.ok {
                r.notes.append("rebuild failed before touching the working toolchain — nothing was changed")
            }
            return r
        }

        let targetSpecs = packages.filter { needed[$0.key] != nil }
        guard !targetSpecs.isEmpty else {
            report.notes.append("every tool is already available — nothing to install")
            return abortBuild(report)
        }
        progress("missing: \(targetSpecs.map { $0.key }.joined(separator: ", "))")

        guard let apt = externalTool("BRIGLIA_TOOLCHAIN_APT", "apt-get") else {
            report.failures.append("apt-get not found — this installer needs a Debian-family system")
            return abortBuild(report)
        }
        guard let dpkg = externalTool("BRIGLIA_TOOLCHAIN_DPKG", "dpkg") else {
            report.failures.append("dpkg not found — this installer needs a Debian-family system")
            return abortBuild(report)
        }

        let lists = aptDir.appendingPathComponent("lists")
        let cache = aptDir.appendingPathComponent("cache")
        let archives = cache.appendingPathComponent("archives")
        let stateDir = aptDir.appendingPathComponent("state")
        for dir in [lists.appendingPathComponent("partial"),
                    archives.appendingPathComponent("partial"),
                    stateDir, buildRoot, probeBinDir, wrapperBinDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Synthetic base status: only what every Debian system guarantees
        // counts as installed, so the download is the tool's full closure.
        guard let realStatus = try? String(contentsOfFile: dpkgStatusPath,
                                           encoding: .utf8) else {
            report.failures.append("cannot read \(dpkgStatusPath) — needed to identify the guaranteed base system")
            return abortBuild(report)
        }
        let baseStatus = stateDir.appendingPathComponent("base-status")
        do {
            try makeSyntheticStatus(realStatusText: realStatus)
                .write(to: baseStatus, atomically: true, encoding: .utf8)
        } catch {
            report.failures.append("could not write the base-system status: \(error.localizedDescription)")
            return abortBuild(report)
        }

        let aptOpts = [
            "-o", "Dir::State=\(aptDir.path)/state",
            "-o", "Dir::State::lists=\(lists.path)",
            "-o", "Dir::State::status=\(baseStatus.path)",
            "-o", "Dir::Cache=\(cache.path)",
            "-o", "Debug::NoLocking=1",
            "-o", "APT::Sandbox::User=\(NSUserName())",
        ]

        progress("updating package lists (on userdata — the rootfs is never touched)…")
        let update = run(apt, aptOpts + ["update"], timeout: 600)
        guard update.exitCode == 0 else {
            report.failures.append("apt update failed: \(update.tail)")
            return abortBuild(report)
        }

        var leanTargets: [String] = []
        var loTargets: [String] = []
        for spec in targetSpecs {
            if spec.key == "libreoffice" {
                let simulate = run(apt, aptOpts + ["install", "--simulate",
                                                   "--no-install-recommends", "-y"]
                                   + spec.apt, timeout: 300)
                if simulate.exitCode == 0 {
                    loTargets = spec.apt
                } else {
                    loTargets = spec.apt.map {
                        $0.replacingOccurrences(of: "-nogui", with: "")
                    }
                    report.notes.append("nogui LibreOffice packages unavailable — using "
                                        + loTargets.joined(separator: ", "))
                }
            } else {
                leanTargets += spec.apt
            }
        }

        progress("downloading the complete package closure for: \(targetSpecs.map { $0.key }.joined(separator: ", "))…")
        if !leanTargets.isEmpty {
            let download = run(apt, aptOpts + ["install", "--download-only",
                                               "--no-install-recommends", "-y"] + leanTargets,
                               timeout: 3600)
            guard download.exitCode == 0 else {
                report.failures.append("apt download failed: \(download.tail)")
                return abortBuild(report)
            }
        }
        if !loTargets.isEmpty {
            // LibreOffice NEEDS its recommends at runtime (field bug, Pixel
            // 2026-08-28: --version worked but real conversions died on
            // libclucene-core.so.1, a recommends-only package). Lean is
            // right for poppler/ffmpeg; wrong here.
            let download = run(apt, aptOpts + ["install", "--download-only",
                                               "-o", "APT::Install-Recommends=true",
                                               "-y"] + loTargets,
                               timeout: 3600)
            guard download.exitCode == 0 else {
                report.failures.append("apt download failed: \(download.tail)")
                return abortBuild(report)
            }
        }

        let debs = (try? fm.contentsOfDirectory(at: archives,
                                                includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "deb" } ?? []
        if debs.isEmpty {
            // Valid when apt considers everything installed yet a binary is
            // missing from disk — report it rather than pretending success.
            report.failures.append(
                "apt downloaded nothing although tools are missing — the "
                + "packages may be marked installed while their files are gone")
            return abortBuild(report)
        }

        progress("extracting \(debs.count) package(s) into the userdata prefix…")
        var skippedBase = Set<String>()
        var extractedVersions: [String: String] = [:]
        for deb in debs {
            let pkg = deb.lastPathComponent.components(separatedBy: "_").first ?? ""
            if isAlwaysSystemPackage(pkg) {
                // The loader-coupled base: the system's ld.so must never
                // resolve against a bundled libc.
                skippedBase.insert(pkg)
                continue
            }
            let extract = run(dpkg, ["-x", deb.path, buildRoot.path], timeout: 300)
            if extract.exitCode != 0 {
                report.failures.append("extract failed for \(deb.lastPathComponent): \(extract.tail)")
            } else if let parsed = parseDebFilename(deb.lastPathComponent) {
                extractedVersions[parsed.name] = parsed.version
            }
        }
        guard report.failures.isEmpty else { return abortBuild(report) }
        if !skippedBase.isEmpty {
            report.notes.append("base system packages kept from the OS (never bundled): "
                                + skippedBase.sorted().joined(separator: ", "))
        }
        report.installedPackages = targetSpecs.map { $0.key }

        if needed["libreoffice"] != nil {
            progress("relocating LibreOffice configuration…")
            if let why = relocateLibreOffice(prefixRoot: buildRoot) {
                report.failures.append("libreoffice: \(why)")
                return abortBuild(report)
            }
        }

        progress("creating wrappers…")
        for spec in targetSpecs {
            for tool in needed[spec.key] ?? [] {
                let why = spec.key == "libreoffice"
                    ? makeLibreOfficeWrapper(name: tool, prefixRoot: buildRoot,
                                             binDir: probeBinDir)
                    : makeWrapper(for: tool, prefixRoot: buildRoot,
                                  binDir: probeBinDir)
                if let why {
                    report.failures.append("\(tool): \(why)")
                } else {
                    report.wrappers.append(tool)
                }
            }
        }

        progress("verifying tools…")
        // Self-healing probe loop (field bug, Pixel 2026-08-28): apt's
        // closure can legitimately omit a library the binary needs at
        // runtime — Debian's BLAS/LAPACK are VIRTUAL packages satisfiable
        // by several providers via alternatives, so "libblas.so.3" counted
        // as satisfied while no provider's file existed on the purged
        // rootfs or in the prefix. When a probe dies on a missing shared
        // object, fetch the owning package by soname convention
        // (libblas.so.3 → libblas3), extract it, refresh the wrapper
        // (new lib subdirs) and probe again.
        var fetchedSonames = Set<String>()
        var recovered: [String] = []
        let libreOfficeTools = Set(needed["libreoffice"] ?? [])
        for tool in report.wrappers {
            var attempts = 0
            while true {
                let wrapper = probeBinDir.appendingPathComponent(tool)
                let probe = probeTool(tool, at: wrapper.path)
                if probe.exitCode == 0 { break }
                guard attempts < 6,
                      let soname = Self.missingSoname(in: probe.output),
                      !fetchedSonames.contains(soname) else {
                    // A broken wrapper shadowing PATH is worse than a
                    // missing tool. (During a rebuild this only removes the
                    // staging probe wrapper — the real one stays untouched.)
                    try? fm.removeItem(at: wrapper)
                    report.failures.append(
                        "\(tool) failed its version probe (exit \(probe.exitCode)) — wrapper removed: \(probe.tail)")
                    break
                }
                attempts += 1
                fetchedSonames.insert(soname)
                progress("fetching missing runtime library \(soname)…")
                guard let pkg = fetchLibraryPackage(for: soname, apt: apt,
                                                    aptOpts: aptOpts,
                                                    dpkg: dpkg,
                                                    archives: archives,
                                                    prefixRoot: buildRoot,
                                                    record: &extractedVersions) else {
                    try? fm.removeItem(at: wrapper)
                    report.failures.append(
                        "\(tool): needs \(soname) and no package providing it could be fetched")
                    break
                }
                recovered.append("\(pkg) → \(soname)")
                // pick up any new lib subdirs
                _ = libreOfficeTools.contains(tool)
                    ? makeLibreOfficeWrapper(name: tool, prefixRoot: buildRoot,
                                             binDir: probeBinDir)
                    : makeWrapper(for: tool, prefixRoot: buildRoot,
                                  binDir: probeBinDir)
            }
        }
        if !recovered.isEmpty {
            report.notes.append("fetched runtime libraries: "
                                + recovered.joined(separator: ", "))
        }

        // Reclaim the big transient artifacts: lists (~220 MB) and .debs are
        // only needed during the install; the extracted prefix is what runs.
        try? fm.removeItem(at: lists)
        try? fm.removeItem(at: cache)
        report.notes.append("apt lists and downloaded archives cleaned up")

        guard rebuildPrefix else {
            // Incremental install: extraction went into the live prefix and
            // the wrappers above are the real ones — nothing to commit.
            // Version manifest: the prefix has no dpkg database, so this
            // record is what `briglia toolchain upgrade` compares against the
            // repo; partial installs merge into it.
            var recorded = loadManifest()
            recorded.merge(extractedVersions) { _, new in new }
            if let why = saveManifestChecked(recorded) {
                report.failures.append("could not record installed versions for future upgrades: \(why)")
            }
            return report
        }
        guard report.ok else { return abortBuild(report) }
        return commitRebuild(report: report,
                             newManifest: extractedVersions,
                             wrapperRollback: wrapperRollback,
                             manifestRollback: manifestRollback,
                             transactionActive: transactionActive,
                             libreOfficeTools: libreOfficeTools,
                             progress: progress)
    }

    /// The commit swap of a transactional rebuild. Everything in staging is
    /// already validated; this makes it live. The only window where a
    /// running daemon can see a half-state is the two renames plus wrapper
    /// regeneration — milliseconds, not the apt run. The COMMIT POINT is a
    /// durable one-file marker write (tx/state = "committed"), deliberately
    /// atomic and cheap; the potentially long backup deletion happens after
    /// it and can only ever cost disk space, never state (Codex round 3 #1).
    private static func commitRebuild(report: InstallReport,
                                      newManifest: [String: String],
                                      wrapperRollback: [String: String],
                                      manifestRollback: [String: String],
                                      transactionActive: Bool,
                                      libreOfficeTools: Set<String>,
                                      progress: (String) -> Void) -> InstallReport {
        var report = report
        let fm = FileManager.default
        var swapped = false

        func rollback(_ why: String) -> InstallReport {
            var r = report
            r.failures.append(why)
            guard swapped else {
                try? fm.removeItem(at: stagingDir)
                try? fm.removeItem(at: txDir)
                r.notes.append("rebuild failed before touching the working toolchain — nothing was changed")
                return r
            }
            do {
                if fm.fileExists(atPath: prefixDir.path) {
                    try fm.removeItem(at: prefixDir)
                }
                if transactionActive, fm.fileExists(atPath: backupDir.path) {
                    try fm.moveItem(at: backupDir, to: prefixDir)
                }
                for (tool, text) in wrapperRollback {
                    let wrapper = wrapperBinDir.appendingPathComponent(tool)
                    try text.write(to: wrapper, atomically: true, encoding: .utf8)
                    try fm.setAttributes([.posixPermissions: 0o755],
                                         ofItemAtPath: wrapper.path)
                }
                // Wrappers this commit wrote for tools that had none before
                // point into the discarded prefix — remove them.
                for tool in r.wrappers where wrapperRollback[tool] == nil {
                    let wrapper = wrapperBinDir.appendingPathComponent(tool)
                    if fm.fileExists(atPath: wrapper.path), isOurWrapper(wrapper.path) {
                        try? fm.removeItem(at: wrapper)
                    }
                }
                if let why2 = saveManifestChecked(manifestRollback) {
                    r.failures.append("rollback could not restore the version manifest: \(why2) — the transaction snapshot is preserved; the next toolchain run finishes the restore")
                    return r  // KEEP tx: recovery converges from it
                }
                try? fm.removeItem(at: stagingDir)
                try? fm.removeItem(at: txDir)
                r.notes.append("rebuild failed — the previous working toolchain was restored")
            } catch {
                // Keep the backup AND the tx snapshot: still "prepared", so
                // the next run's recovery restores everything from them.
                r.failures.append("rollback also failed: \(error.localizedDescription) — the previous state is preserved (snapshot at \(txDir.path)); the next toolchain run restores it")
            }
            return r
        }

        progress("switching to the rebuilt prefix…")
        // The staging probe bin must not travel into the live prefix.
        try? fm.removeItem(at: stagingDir.appendingPathComponent(".ada-probe-bin"))
        if transactionActive {
            do { try fm.moveItem(at: prefixDir, to: backupDir) } catch {
                return rollback("could not set the working prefix aside for the swap: \(error.localizedDescription)")
            }
        }
        swapped = true
        do { try fm.moveItem(at: stagingDir, to: prefixDir) } catch {
            return rollback("could not move the rebuilt prefix into place: \(error.localizedDescription)")
        }

        // LibreOffice's rc files carry absolute paths baked during the
        // staging build — rebase them onto the final prefix path.
        let loProgram = prefixDir.appendingPathComponent("usr/lib/libreoffice/program")
        if fm.fileExists(atPath: loProgram.path),
           let why = rebaseTextFiles(in: loProgram, suffix: "rc",
                                     from: stagingDir.path, to: prefixDir.path) {
            return rollback("could not rebase LibreOffice configuration: \(why)")
        }

        progress("verifying the switched toolchain…")
        for tool in report.wrappers.sorted() {
            let why = libreOfficeTools.contains(tool)
                ? makeLibreOfficeWrapper(name: tool)
                : makeWrapper(for: tool)
            if let why { return rollback("\(tool): \(why)") }
            let probe = probeTool(tool, at: wrapperBinDir.appendingPathComponent(tool).path)
            guard probe.exitCode == 0 else {
                return rollback("\(tool) failed its post-switch probe (exit \(probe.exitCode)): \(probe.tail)")
            }
        }
        // A rebuild starts the version record over.
        if let why = saveManifestChecked(newManifest) {
            return rollback("could not record the rebuilt versions: \(why)")
        }

        if transactionActive {
            // STORAGE BARRIER before the marker (Codex round 4): the
            // committed marker must never become durable while the state it
            // certifies — extracted prefix files, the swap renames, the new
            // wrappers, the manifest, the rebased rc files — is still in
            // volatile caches. syncfs both filesystems involved (the data
            // root and the wrapper bin dir can differ), CHECKED; only then
            // may "committed" be written. Recovery's unconditional trust in
            // the marker is sound precisely because of this ordering.
            if let why = flushStorage([root, wrapperBinDir]) {
                return rollback("could not flush the switched toolchain to stable storage: \(why)")
            }
            if let why = writeDurable("committed", to: txStateURL) {
                return rollback("could not persist the commit marker: \(why)")
            }
            // Cleanup after the commit point: failures here cost only disk
            // space and are retried by the next run's recovery.
            do {
                try fm.removeItem(at: backupDir)
                try? fm.removeItem(at: txDir)
            } catch {
                report.notes.append("installed, but the previous toolchain's backup could not be cleaned up yet (\(backupDir.path)): \(error.localizedDescription) — the next toolchain run retries the cleanup")
            }
        }
        return report
    }

    /// Replace every occurrence of `old` with `new` in `dir`'s files whose
    /// names end in `suffix`. Returns nil on success, else a one-line reason.
    private static func rebaseTextFiles(in dir: URL, suffix: String,
                                        from old: String, to new: String) -> String? {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
            where name.hasSuffix(suffix) {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(old) else { continue }
            do {
                try text.replacingOccurrences(of: old, with: new)
                    .write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "could not rewrite \(name): \(error.localizedDescription)"
            }
        }
        return nil
    }

    struct RemoveResult {
        var removed: [String] = []
        var failure: String?
        var ok: Bool { failure == nil }
    }

    /// Remove every wrapper we created plus the prefix. Foreign files in the
    /// bin dir (no marker) are never touched. Refuses while another
    /// toolchain operation holds the lock (removing a prefix mid-rebuild
    /// would corrupt the rebuild's transaction) — the lock file itself lives
    /// BESIDE the root, so deleting the root cannot unlink a held lock
    /// (Codex round 3 #3). A typed failure, never a fake removed-item string.
    static func removeAll() -> RemoveResult {
        let fm = FileManager.default
        var result = RemoveResult()
        let lock = acquireLock()
        guard let lockFD = lock.fd else {
            result.failure = (lock.failure ?? "could not acquire the toolchain lock")
                + " — nothing removed"
            return result
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }
        let allTools = packages.flatMap { $0.tools }
        for tool in allTools {
            let wrapper = wrapperBinDir.appendingPathComponent(tool)
            if fm.fileExists(atPath: wrapper.path), isOurWrapper(wrapper.path) {
                do {
                    try fm.removeItem(at: wrapper)
                    result.removed.append(tool)
                } catch {
                    result.failure = "could not remove the \(tool) wrapper: \(error.localizedDescription)"
                    return result
                }
            }
        }
        if fm.fileExists(atPath: root.path) {
            do {
                try fm.removeItem(at: root)
                result.removed.append("(prefix)")
            } catch {
                result.failure = "could not remove the prefix at \(root.path): \(error.localizedDescription)"
            }
        }
        return result
    }

    // -------------------------------------------- synthetic base status

    /// True for packages that must always come from the OS and are never
    /// bundled: the loader-coupled libc family (a prefix libc under the
    /// system's ld.so is a crash) and its immediate runtime kin. Everything
    /// here is something a Debian system cannot boot without, so neither a
    /// purge nor an OTA can legitimately remove it.
    static func isAlwaysSystemPackage(_ name: String) -> Bool {
        if ["libc6", "libc-bin", "libgcc-s1", "libcrypt1"].contains(name) {
            return true
        }
        if name.hasPrefix("libc6-") { return true }
        if name.hasPrefix("gcc-") && name.hasSuffix("-base") { return true }
        return false
    }

    /// The dpkg status handed to apt for closure resolution: only stanzas
    /// for the guaranteed base system (Essential: yes, Priority: required,
    /// the libc family), dependency-closed within the real status so apt
    /// never sees a "broken" installed set. Every other package — installed
    /// on the rootfs or not — resolves as missing and downloads into the
    /// prefix, which is what makes prefixes immune to later purges/OTAs.
    static func makeSyntheticStatus(realStatusText: String) -> String {
        struct Entry {
            let name: String
            let text: String
            let provides: [String]
            let deps: [String]
            let keepSeed: Bool
        }
        func field(_ stanza: String, _ key: String) -> String? {
            for line in stanza.split(separator: "\n")
                where line.hasPrefix(key + ":") {
                return String(line.dropFirst(key.count + 1))
                    .trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        func names(inRelation raw: String) -> [String] {
            // "libgcc-s1 (>= 3.0), libc6 | libc6.1, foo:any" → bare names
            raw.components(separatedBy: ",")
                .flatMap { $0.components(separatedBy: "|") }
                .compactMap { clause -> String? in
                    let trimmed = clause.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return nil }
                    let name = trimmed.prefix {
                        $0 != " " && $0 != "(" && $0 != ":"
                    }
                    return name.isEmpty ? nil : String(name)
                }
        }

        var entries: [Entry] = []
        for stanza in realStatusText.components(separatedBy: "\n\n") {
            let trimmed = stanza.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let name = field(trimmed, "Package") else { continue }
            guard (field(trimmed, "Status") ?? "").hasSuffix("installed") else { continue }
            let essential = field(trimmed, "Essential") == "yes"
            let required = field(trimmed, "Priority") == "required"
            entries.append(Entry(
                name: name,
                text: trimmed,
                provides: names(inRelation: field(trimmed, "Provides") ?? ""),
                deps: names(inRelation: field(trimmed, "Depends") ?? "")
                    + names(inRelation: field(trimmed, "Pre-Depends") ?? ""),
                keepSeed: essential || required || isAlwaysSystemPackage(name)))
        }

        var index: [String: [Int]] = [:]
        for (i, entry) in entries.enumerated() {
            index[entry.name, default: []].append(i)
            for provided in entry.provides {
                index[provided, default: []].append(i)
            }
        }

        var keep = Set(entries.indices.filter { entries[$0].keepSeed })
        var frontier = keep
        while !frontier.isEmpty {
            var next = Set<Int>()
            for i in frontier {
                for dep in entries[i].deps {
                    for j in index[dep] ?? [] where !keep.contains(j) {
                        keep.insert(j)
                        next.insert(j)
                    }
                }
            }
            frontier = next
        }

        let kept = keep.sorted().map { entries[$0].text }
        return kept.isEmpty ? "" : kept.joined(separator: "\n\n") + "\n"
    }

    // ---------------------------------------------------------- helpers

    /// One verification probe. Most tools answer a version flag; the
    /// LibreOffice pair gets a REAL headless txt→PDF conversion — field
    /// bug (Pixel 2026-08-28): `soffice --version` succeeds even when a
    /// conversion-path library (libclucene) is missing, so a version
    /// probe certifies a broken tool.
    static func probeTool(_ tool: String, at path: String) -> RunResult {
        guard tool == "soffice" || tool == "libreoffice" else {
            return run(path, probeArgs[tool] ?? ["--version"], timeout: 60)
        }
        let fm = FileManager.default
        let probeRoot = root.appendingPathComponent("probe-tmp")
        let dir = probeRoot.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: probeRoot) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let txt = dir.appendingPathComponent("probe.txt")
        do {
            try "briglia toolchain conversion probe".write(to: txt, atomically: true,
                                                       encoding: .utf8)
        } catch {
            return RunResult(exitCode: 1,
                             output: "could not stage the conversion probe: \(error.localizedDescription)")
        }
        let result = run(path, ["--headless", "--convert-to", "pdf",
                                "--outdir", dir.path, txt.path], timeout: 300)
        if result.exitCode != 0 { return result }
        let pdfSize = (try? fm.attributesOfItem(
            atPath: dir.appendingPathComponent("probe.pdf").path))?[.size] as? Int ?? 0
        if pdfSize > 0 { return result }
        return RunResult(exitCode: 1,
                         output: result.output + "\n(conversion probe produced no PDF)")
    }

    /// "error while loading shared libraries: libblas.so.3: cannot open…"
    /// → "libblas.so.3"
    static func missingSoname(in output: String) -> String? {
        guard let range = output.range(of: "loading shared libraries: ") else {
            return nil
        }
        let rest = output[range.upperBound...]
        let name = rest.prefix { $0 != ":" && !$0.isWhitespace }
        return name.contains(".so") ? String(name) : nil
    }

    /// libblas.so.3 → [libblas3, libblas3t64, libblas-3, libblas] (Debian
    /// shared-lib package naming conventions, most common first; the t64
    /// variant covers noble's time64 renames, e.g. libclucene-core.so.1 →
    /// libclucene-core1t64).
    static func sonamePackageCandidates(_ soname: String) -> [String] {
        guard let soRange = soname.range(of: ".so") else { return [] }
        let base = String(soname[..<soRange.lowerBound])
        let parts = soname.components(separatedBy: ".so.")
        let version = parts.count > 1 ? parts[1] : ""
        var out: [String] = []
        if !version.isEmpty {
            out.append(base + version)
            out.append(base + version + "t64")
            out.append(base + "-" + version)
        }
        out.append(base)
        return out
    }

    /// `apt-get download <candidate>` (redirected opts, cwd = archives) and
    /// extract whatever new .debs appear. Returns the package name that
    /// worked, or nil. Extracted versions land in `record` for the
    /// upgrade manifest.
    private static func fetchLibraryPackage(for soname: String, apt: String,
                                            aptOpts: [String], dpkg: String,
                                            archives: URL,
                                            prefixRoot: URL,
                                            record: inout [String: String]) -> String? {
        let fm = FileManager.default
        for candidate in sonamePackageCandidates(soname) {
            let before = Set((try? fm.contentsOfDirectory(atPath: archives.path)) ?? [])
            let result = run(apt, aptOpts + ["download", candidate],
                             timeout: 600, cwd: archives)
            guard result.exitCode == 0 else { continue }
            let after = (try? fm.contentsOfDirectory(atPath: archives.path)) ?? []
            let fresh = after.filter { !before.contains($0) && $0.hasSuffix(".deb") }
            guard !fresh.isEmpty else { continue }
            var extracted = false
            for deb in fresh {
                let path = archives.appendingPathComponent(deb)
                if run(dpkg, ["-x", path.path, prefixRoot.path], timeout: 300)
                    .exitCode == 0 {
                    extracted = true
                    if let parsed = parseDebFilename(deb) {
                        record[parsed.name] = parsed.version
                    }
                }
            }
            if extracted { return candidate }
        }
        return nil
    }

    // ------------------------------------------------------------ upgrade

    /// name_version_arch.deb → (name, version). apt URL-encodes epochs in
    /// filenames (1%3a2.39 → 1:2.39).
    static func parseDebFilename(_ filename: String) -> (name: String, version: String)? {
        guard filename.hasSuffix(".deb") else { return nil }
        let parts = String(filename.dropLast(4)).components(separatedBy: "_")
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1].removingPercentEncoding ?? parts[1])
    }

    static var manifestURL: URL { root.appendingPathComponent("installed-packages.json") }

    static func loadManifest() -> [String: String] {
        guard let data = try? Data(contentsOf: manifestURL),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    /// Returns nil on success, else a one-line reason. Checked everywhere:
    /// a silently unsaved manifest makes `toolchain upgrade` compare the
    /// repo against versions the prefix doesn't actually have. Durable
    /// (fsync + rename) so the record survives power loss with the state
    /// it describes.
    private static func saveManifestChecked(_ map: [String: String]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return writeDurable(try encoder.encode(map), to: manifestURL)
        } catch {
            return error.localizedDescription
        }
    }

    /// The prefix is frozen at install-time versions and dpkg knows nothing
    /// about it, so security fixes (poppler/ImageMagick parse UNTRUSTED
    /// input) would never arrive — the one real downside of the userdata
    /// design. This closes it: refresh the lists, compare every recorded
    /// package against the repo candidate, and rebuild the whole prefix
    /// self-contained when anything is stale. A package that vanished from
    /// the repo (e.g. a t64 rename) counts as stale — the rebuild's fresh
    /// closure resolution picks up its successor and the manifest converges.
    static func upgradeSync(progress: (String) -> Void) -> InstallReport {
        var report = InstallReport()
        let fm = FileManager.default

        let lock = acquireLock()
        guard let lockFD = lock.fd else {
            report.failures.append(lock.failure ?? "could not acquire the toolchain lock")
            return report
        }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }

        // Recover any interrupted rebuild BEFORE reading the manifest: a
        // crashed transaction can leave a manifest claiming versions the
        // prefix doesn't have, and comparing THAT against the repo would
        // wrongly report "everything up to date".
        if let failure = recoverInterrupted(&report) {
            report.failures.append(failure)
            return report
        }

        let recorded = loadManifest()
        guard !recorded.isEmpty else {
            report.notes.append("no userdata toolchain recorded — run `briglia toolchain install` first")
            return report
        }
        guard let apt = externalTool("BRIGLIA_TOOLCHAIN_APT", "apt-get") else {
            report.failures.append("apt-get not found — this installer needs a Debian-family system")
            return report
        }
        guard let dpkg = externalTool("BRIGLIA_TOOLCHAIN_DPKG", "dpkg") else {
            report.failures.append("dpkg not found — this installer needs a Debian-family system")
            return report
        }

        let lists = aptDir.appendingPathComponent("lists")
        let cache = aptDir.appendingPathComponent("cache")
        let archives = cache.appendingPathComponent("archives")
        for dir in [lists.appendingPathComponent("partial"),
                    archives.appendingPathComponent("partial"),
                    aptDir.appendingPathComponent("state")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let aptOpts = [
            "-o", "Dir::State=\(aptDir.path)/state",
            "-o", "Dir::State::lists=\(lists.path)",
            "-o", "Dir::Cache=\(cache.path)",
            "-o", "Debug::NoLocking=1",
            "-o", "APT::Sandbox::User=\(NSUserName())",
        ]

        progress("refreshing package lists (on userdata, cleaned up after)…")
        let update = run(apt, aptOpts + ["update"], timeout: 600)
        guard update.exitCode == 0 else {
            report.failures.append("apt update failed: \(update.tail)")
            return report
        }

        // Candidate versions via --print-uris (resolves, downloads nothing).
        // Batch first; if any recorded package no longer resolves, isolate
        // per-package so one rename doesn't hide everything else.
        let names = recorded.keys.sorted()
        progress("checking \(names.count) recorded package(s) against the repo…")
        var candidates: [String: String] = [:]
        var vanished: [String] = []
        func harvest(_ output: String) {
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: " ")
                guard fields.count >= 2,
                      let parsed = parseDebFilename(String(fields[1])) else { continue }
                candidates[parsed.name] = parsed.version
            }
        }
        let batch = run(apt, aptOpts + ["download", "--print-uris"] + names,
                        timeout: 600, cwd: archives)
        if batch.exitCode == 0 {
            harvest(batch.output)
        } else {
            for name in names {
                let single = run(apt, aptOpts + ["download", "--print-uris", name],
                                 timeout: 120, cwd: archives)
                if single.exitCode == 0 { harvest(single.output) }
            }
        }

        var stale: [String] = []
        for name in names {
            guard let candidate = candidates[name] else {
                vanished.append(name)
                continue
            }
            let current = recorded[name] ?? ""
            if current != candidate,
               run(dpkg, ["--compare-versions", current, "lt", candidate],
                   timeout: 30).exitCode == 0 {
                stale.append("\(name) \(current) → \(candidate)")
            }
        }
        if !vanished.isEmpty {
            report.notes.append("no longer in the repo (renamed/replaced — the rebuild resolves successors): "
                                + vanished.joined(separator: ", "))
        }

        guard !stale.isEmpty || !vanished.isEmpty else {
            report.notes.append("everything up to date (\(names.count) packages checked)")
            try? fm.removeItem(at: lists)
            try? fm.removeItem(at: cache)
            return report
        }

        if !stale.isEmpty {
            progress("newer versions available:")
            for line in stale { progress("  \(line)") }
            report.notes.append("upgraded: " + stale.joined(separator: ", "))
        }
        progress("rebuilding the prefix at current repo versions…")
        // Locked variant: this call already holds the toolchain lock.
        var install = installSyncLocked(includePandoc: false, includeLibreOffice: false,
                                        forceRebuild: true, progress: progress)
        install.notes.append(contentsOf: report.notes)
        return install
    }

    /// Arch-triple lib dirs in the prefix, plus any alternatives-provider
    /// subdirs that hold shared objects (Debian's BLAS/LAPACK live in
    /// <arch>/blas/libblas.so.3 etc. — the postinst symlink that would
    /// surface them never runs under dpkg -x).
    private static func prefixLibDirs(prefixRoot: URL = prefixDir) -> [String] {
        let fm = FileManager.default
        var libDirs: [String] = []
        let libRoot = prefixRoot.appendingPathComponent("usr/lib")
        if let entries = try? fm.contentsOfDirectory(atPath: libRoot.path) {
            for entry in entries.sorted() where entry.contains("-linux-gnu") {
                let archDir = libRoot.appendingPathComponent(entry)
                libDirs.append(archDir.path)
                for sub in (try? fm.contentsOfDirectory(atPath: archDir.path))?.sorted() ?? [] {
                    let subDir = archDir.appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: subDir.path, isDirectory: &isDir),
                          isDir.boolValue,
                          let files = try? fm.contentsOfDirectory(atPath: subDir.path),
                          files.contains(where: { $0.contains(".so") })
                    else { continue }
                    libDirs.append(subDir.path)
                }
            }
        }
        libDirs.append(libRoot.path)
        libDirs.append(prefixRoot.appendingPathComponent("lib").path)
        return libDirs
    }

    /// Returns nil on success, else a one-line reason.
    private static func writeWrapper(name: String, lines: [String],
                                     into binDir: URL) -> String? {
        let fm = FileManager.default
        let wrapper = binDir.appendingPathComponent(name)
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: wrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        } catch {
            return "could not write wrapper: \(error.localizedDescription)"
        }
        return nil
    }

    /// Returns nil on success, else a one-line reason.
    private static func makeWrapper(for tool: String,
                                    prefixRoot: URL = prefixDir,
                                    binDir wrapperDir: URL? = nil) -> String? {
        let fm = FileManager.default
        let binDir = prefixRoot.appendingPathComponent("usr/bin")
        var real = binDir.appendingPathComponent(tool)
        if !fm.isExecutableFile(atPath: real.path) {
            // ImageMagick alternatives: the deb ships convert-im6.q16 etc.;
            // the plain name would have been a postinst-managed symlink.
            let variants = (try? fm.contentsOfDirectory(atPath: binDir.path))?
                .filter { $0.hasPrefix(tool + "-im") }.sorted() ?? []
            guard let variant = variants.first else {
                return "no binary for \(tool) in the extracted prefix"
            }
            real = binDir.appendingPathComponent(variant)
        }

        let libDirs = prefixLibDirs(prefixRoot: prefixRoot)
        var lines = [
            "#!/bin/sh",
            wrapperMarker,
            closureMarker,
            "export LD_LIBRARY_PATH=\"\(libDirs.joined(separator: ":")):${LD_LIBRARY_PATH:-}\"",
        ]
        let libRoot = prefixRoot.appendingPathComponent("usr/lib")
        if let coders = firstCodersDir(under: libRoot.path) {
            lines.append("export MAGICK_CODER_MODULE_PATH=\"\(coders)\"")
        }
        if let conf = (try? fm.contentsOfDirectory(atPath: prefixRoot.appendingPathComponent("etc").path))?
            .filter({ $0.hasPrefix("ImageMagick") }).sorted().first {
            lines.append("export MAGICK_CONFIGURE_PATH=\"\(prefixRoot.path)/etc/\(conf)\"")
        }
        lines.append("exec \"\(real.path)\" \"$@\"")
        return writeWrapper(name: tool, lines: lines,
                            into: wrapperDir ?? wrapperBinDir)
    }

    // ------------------------------------------------------- libreoffice

    /// dpkg -x never runs LibreOffice's maintainer scripts, and its rc
    /// files hardcode BRAND_BASE_DIR=file:///usr/lib/libreoffice plus
    /// configuration layers under /etc/libreoffice/registry (populated by
    /// a postinst). Point every program/*rc at the prefix, and at the
    /// registry the deb actually ships (share/.registry on Debian/Ubuntu)
    /// when /etc was never populated. Field-proven: without this soffice
    /// aborts at bootstrap (Pixel PoC round 3, 2026-08-28).
    static func relocateLibreOffice(prefixRoot: URL = prefixDir) -> String? {
        let fm = FileManager.default
        let loRoot = prefixRoot.appendingPathComponent("usr/lib/libreoffice")
        let program = loRoot.appendingPathComponent("program")
        guard fm.fileExists(atPath: program.path) else {
            return "usr/lib/libreoffice/program missing after extraction"
        }
        // The deb ships the REAL .xcd files in share/.registry; the
        // /etc/libreoffice/registry it also ships holds only *.sample
        // files (the postinst would copy the real ones there). Field bug
        // (Pixel 2026-08-28): preferring an existing-but-sample-only /etc
        // dir gave configmgr a registry without main.xcd → soffice aborts
        // with com::sun::star::container::NoSuchElementException. Pick the
        // first candidate that actually contains .xcd data.
        let registry = ["usr/lib/libreoffice/share/.registry",
                        "etc/libreoffice/registry",
                        "usr/lib/libreoffice/share/registry"]
            .map { prefixRoot.appendingPathComponent($0) }
            .first { dir in
                guard let files = try? fm.contentsOfDirectory(atPath: dir.path)
                else { return false }
                return files.contains { $0.hasSuffix(".xcd") }
            }
        // Placeholder tokens keep the two replacements from mangling each
        // other: the relocated registry path itself contains the string
        // "/usr/lib/libreoffice".
        let loToken = "\u{1}BRIGLIA_LO\u{1}"
        let regToken = "\u{1}BRIGLIA_REG\u{1}"
        var rewrote = 0
        for name in (try? fm.contentsOfDirectory(atPath: program.path))?.sorted() ?? []
            where name.hasSuffix("rc") {
            let url = program.appendingPathComponent(name)
            guard var text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("/usr/lib/libreoffice") || text.contains("/etc/libreoffice")
            else { continue }
            text = text.replacingOccurrences(of: "/etc/libreoffice/registry", with: regToken)
            text = text.replacingOccurrences(of: "/usr/lib/libreoffice", with: loToken)
            text = text.replacingOccurrences(of: loToken, with: loRoot.path)
            text = text.replacingOccurrences(
                of: regToken,
                with: registry?.path ?? loRoot.path + "/share/.registry")
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { return "could not rewrite \(name): \(error.localizedDescription)" }
            rewrote += 1
        }
        if rewrote == 0 {
            // Idempotent re-run: already relocated is fine; nothing at all is not.
            let fundamental = program.appendingPathComponent("fundamentalrc")
            if let text = try? String(contentsOf: fundamental, encoding: .utf8),
               text.contains(loRoot.path) {
                return nil
            }
            return "no rc files found to relocate"
        }
        return nil
    }

    /// Returns nil on success, else a one-line reason.
    private static func makeLibreOfficeWrapper(name: String,
                                               prefixRoot: URL = prefixDir,
                                               binDir wrapperDir: URL? = nil) -> String? {
        let fm = FileManager.default
        let program = prefixRoot.appendingPathComponent("usr/lib/libreoffice/program")
        let soffice = program.appendingPathComponent("soffice")
        guard fm.isExecutableFile(atPath: soffice.path) else {
            return "no binary for soffice in the extracted prefix"
        }
        // program/ first: LibreOffice's private libs (libreglo.so & friends)
        // live there and are on no standard lib path — field lesson.
        let libDirs = [program.path] + prefixLibDirs(prefixRoot: prefixRoot)
        let userInstall = root.appendingPathComponent("louser")
        let lines = [
            "#!/bin/sh",
            wrapperMarker,
            closureMarker,
            "export LD_LIBRARY_PATH=\"\(libDirs.joined(separator: ":")):${LD_LIBRARY_PATH:-}\"",
            "export SAL_USE_VCLPLUGIN=svp",
            "exec \"\(soffice.path)\" \"-env:UserInstallation=file://\(userInstall.path)\" \"$@\"",
        ]
        return writeWrapper(name: name, lines: lines,
                            into: wrapperDir ?? wrapperBinDir)
    }

    /// e.g. usr/lib/<arch>/ImageMagick-6.9.12/modules-Q16/coders — the
    /// coder-module dir ImageMagick needs exported when relocated.
    private static func firstCodersDir(under underPath: String) -> String? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: underPath) else { return nil }
        var hits: [String] = []
        for case let rel as String in walker {
            guard rel.contains("ImageMagick"), rel.hasSuffix("/coders") else { continue }
            var isDir: ObjCBool = false
            let full = underPath + "/" + rel
            if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                hits.append(full)
            }
        }
        return hits.sorted().first
    }

    struct RunResult {
        let exitCode: Int32
        let output: String
        var tail: String {
            let lines = output.split(separator: "\n")
            return lines.suffix(3).joined(separator: " | ")
        }
    }

    /// Internal (not private) so the selftest can exercise the timeout path.
    static func run(_ executable: String, _ args: [String],
                    timeout: TimeInterval, cwd: URL? = nil) -> RunResult {
        let process = Process()
        // The `briglia __setsid-exec` trampoline makes the child a session (and
        // process-group) leader, so a timeout can kill the WHOLE apt/dpkg
        // tree — terminating only the immediate Process left descendants
        // alive and mutating the prefix after we reported the timeout
        // (Codex regression audit, 2026-08-29).
        let (exe, launchArgs) = BashTools.detachedInvocation(
            executable: executable, arguments: args)
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = launchArgs
        if let cwd { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["DEBIAN_FRONTEND"] = "noninteractive"
        // Side channel from the trampoline: the pid of the DETACHED session
        // leader. Foundation Process already makes its child a group leader,
        // so the trampoline's setsid-in-place fails and its posix_spawn
        // fallback puts the real tree in the CHILD's own session — the
        // tracked pid's group then contains only the shim, and killing it
        // never reaches apt/dpkg (Codex round 2 #2: kill(-trackedPid) was
        // ESRCH once the shim exited).
        let pgidFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ada-toolchain-pgid-\(UUID().uuidString)")
        env["BRIGLIA_SETSID_PGID_FILE"] = pgidFile.path
        defer { try? FileManager.default.removeItem(at: pgidFile) }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        var data = Data()
        do {
            try process.run()
            let reader = Thread {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
            }
            reader.start()
            let pid = process.processIdentifier
            // Kill the REAL tree's group (leader pid reported by the
            // trampoline through the side channel), plus the tracked
            // pid/group as fallback — while the shim is alive it forwards
            // TERM/INT/HUP to the child's group itself, and non-absolute
            // executables skip the trampoline entirely.
            func signalTree(_ sig: Int32) {
                if let text = try? String(contentsOfFile: pgidFile.path,
                                          encoding: .utf8),
                   let leader = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   leader > 0 {
                    kill(-leader, sig)
                }
                if kill(-pid, sig) != 0 { kill(pid, sig) }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                signalTree(SIGTERM)
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning { signalTree(SIGKILL) }
                process.waitUntilExit()
                // Sweep group members that outlived the leader's exit.
                signalTree(SIGKILL)
                // Join the reader so nothing writes `data` after we return.
                // Bounded: a descendant that re-led its own group could in
                // principle survive and hold the pipe open.
                let readerDeadline = Date().addingTimeInterval(5)
                while reader.isExecuting && Date() < readerDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                let captured = reader.isExecuting
                    ? "(output unavailable — a straggler still holds the pipe)"
                    : (String(data: data, encoding: .utf8) ?? "")
                return RunResult(exitCode: 124,
                                 output: "timed out after \(Int(timeout))s\n" + captured)
            }
            // Leader exited. Normally the pipe closes right behind it — but
            // a command that detached a child and exited early ("cmd &" then
            // exit) leaves the write end open in that child, and an
            // unbounded reader wait here hung the whole install (Codex
            // round 2: the timeout branch above never fires because the
            // tracked process is no longer running). Wait only until the
            // same deadline, then kill the group the leader led — the group
            // id outlives its leader while members remain (verified live,
            // macOS + Linux) — and reclaim the pipe.
            while reader.isExecuting && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            var stragglersKilled = false
            if reader.isExecuting {
                stragglersKilled = true
                signalTree(SIGTERM)
                let grace = Date().addingTimeInterval(2)
                while reader.isExecuting && Date() < grace {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if reader.isExecuting {
                    signalTree(SIGKILL)
                    let finalJoin = Date().addingTimeInterval(5)
                    while reader.isExecuting && Date() < finalJoin {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
            }
            process.waitUntilExit()
            if reader.isExecuting {
                // A descendant re-led its own group and survived — give up
                // on the pipe rather than hang; never touch `data` while
                // the reader thread might still write it.
                return RunResult(exitCode: 124,
                                 output: "the command exited but a detached descendant still holds its output pipe — process group killed, output unavailable")
            }
            if stragglersKilled {
                let text = String(data: data, encoding: .utf8) ?? ""
                // Forcibly killing part of the command's process tree is not
                // success, whatever the leader's own exit status said — a
                // truncated apt/dpkg must never be treated as clean (Codex
                // round 3 #2: exit 0 here made callers ignore the note).
                let status = process.terminationStatus
                return RunResult(exitCode: status == 0 ? 124 : status,
                                 output: text
                                 + "\n(detached descendant processes outlived the command and were killed — treated as failure)")
            }
        } catch {
            return RunResult(exitCode: 127, output: "launch failed: \(error.localizedDescription)")
        }
        return RunResult(exitCode: process.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "")
    }
}
