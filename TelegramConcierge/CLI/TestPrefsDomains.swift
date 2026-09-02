import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Throwaway UserDefaults domains created by the selftests are removed
/// COMPLETELY when a run finishes. `removePersistentDomain` alone empties
/// the domain, but cfprefsd (macOS) then writes a 42-byte empty plist shell
/// for it a few seconds later (measured: ~5.6 s after the removal, from a
/// timer — also after the removing process has exited), so hundreds of
/// shells accumulated in ~/Library/Preferences; `defaults delete` reports
/// such a domain as "not found" and leaves the file. The purge therefore
/// records every removed domain, and the final sweep — run once, at the
/// end of the selftest — waits for each recorded shell to become empty
/// (or vanish) and unlinks it. Guarded by name prefix so it can never touch
/// a real domain.
enum TestPrefsDomains {
    /// Every prefix a selftest may use for a throwaway domain. The smoke
    /// suite counts files matching these before and after a run.
    static let testPrefixes = ["ada-mig-probe-", "ada-mig-st-", "ada-setup-api-selftest-",
                               "briglia-s4-"]

    static func isTestDomain(_ name: String) -> Bool {
        testPrefixes.contains { name.hasPrefix($0) }
    }

    private static let lock = NSLock()
    private static var purged: [String] = []

    /// Candidate on-disk locations of a domain's plist: the passwd home and
    /// $HOME (corelibs persists under $HOME, which differs from the passwd
    /// home on hosted CI containers).
    static func candidatePaths(_ name: String) -> [String] {
        var homes = [FileManager.default.homeDirectoryForCurrentUser.path]
        if let envHome = ProcessInfo.processInfo.environment["HOME"], !envHome.isEmpty,
           !homes.contains(envHome) {
            homes.append(envHome)
        }
        var out: [String] = []
        for home in homes {
            out += [home + "/Library/Preferences/\(name).plist",
                    home + "/.config/\(name).plist",
                    home + "/.local/share/\(name).plist"]
        }
        return out
    }

    /// Remove the domain now and remember it for the final sweep.
    static func purge(_ name: String) {
        guard isTestDomain(name) else { return }
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: name)
        defaults.synchronize()
        lock.lock(); defer { lock.unlock() }
        if !purged.contains(name) { purged.append(name) }
    }

    /// True when the file at `path` is gone or holds an empty plist
    /// dictionary (the shell) — i.e. nothing is left to preserve.
    private static func isEmptyShellOrGone(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return true }
        guard let data = fm.contents(atPath: path) else { return false }
        if data.isEmpty { return true }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return false
        }
        if let dict = plist as? [String: Any] { return dict.isEmpty }
        return false
    }

    /// Wait (bounded) for every purged domain's on-disk shell to become
    /// empty, then unlink it. Returns the names still holding data after
    /// the timeout — the caller reports them; they will also fail the smoke
    /// suite's count check.
    @discardableResult
    static func finalSweep(timeout: TimeInterval = 12) -> [String] {
        lock.lock()
        let names = purged
        lock.unlock()
        guard !names.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(timeout)
        var pending = Set(names)
        while !pending.isEmpty {
            for name in Array(pending) {
                let paths = candidatePaths(name)
                if paths.allSatisfy(isEmptyShellOrGone) {
                    for path in paths where FileManager.default.fileExists(atPath: path) {
                        unlink(path)
                    }
                    pending.remove(name)
                }
            }
            if pending.isEmpty || Date() >= deadline { break }
            usleep(200_000)
        }
        // Unlink whatever became empty during the last poll as well.
        for name in pending {
            for path in candidatePaths(name)
                where FileManager.default.fileExists(atPath: path) && isEmptyShellOrGone(path) {
                unlink(path)
            }
        }
        lock.lock(); purged.removeAll(); lock.unlock()
        return pending.sorted()
    }
}
