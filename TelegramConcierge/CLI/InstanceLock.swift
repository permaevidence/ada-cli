import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Exclusive per-user lock for conversation-owning modes (`briglia` chat and
/// `briglia daemon`). Two such processes would long-poll the same Telegram bot
/// (Telegram splits updates randomly between competing pollers) and race on
/// the same conversation, archive and reminder files — so the second one
/// must refuse to start instead of silently corrupting shared state.
///
/// Uses flock(2): advisory, and released automatically when the process dies
/// for any reason, so a crash can never leave a stale lock behind. `ada
/// setup` / `briglia doctor` deliberately do NOT take the lock — they must work
/// while a daemon is running.
enum InstanceLock {
    private static var lockFd: Int32 = -1

    /// Try to take the exclusive lock. Returns nil on success, or a
    /// human-readable reason when another instance already holds it.
    static func acquire() -> String? {
        let url = StoragePaths.dataRoot.appendingPathComponent("instance.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            return "cannot open \(url.path): \(String(cString: strerror(errno)))"
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Best-effort: report the holder's pid recorded at acquire time.
            var holder = ""
            var buf = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buf, buf.count, 0)
            if n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) {
                let pid = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pid.isEmpty { holder = " (pid \(pid))" }
            }
            close(fd)
            return "another Briglia instance\(holder) is already running — `briglia` chat and "
                + "`briglia daemon` share one conversation and one Telegram poller, so only "
                + "one can be active. Quit the other instance first."
        }
        let pid = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        // Close-on-exec, for two reasons: child processes (background bash,
        // language servers) must not inherit the fd — a lingering child would
        // keep the lock held after we exit and block the next `briglia` — and the
        // /upgrade self-restart re-execs in place, where the inherited lock
        // would deadlock the new image against its own predecessor.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        lockFd = fd  // keep open for process lifetime; flock dies with us
        return nil
    }
}
