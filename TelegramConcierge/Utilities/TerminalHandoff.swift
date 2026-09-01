import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Foundation's `Process` spawns every child into its own process group
/// (`POSIX_SPAWN_SETPGROUP`, hardcoded in swift-corelibs-foundation and
/// Darwin Foundation alike — no opt-out). For piped children that is
/// invisible, but a child that must converse with the controlling terminal
/// (sudo password prompt, apt-get conffile/trigger questions) becomes a
/// *background* job of that terminal: its first tty read delivers SIGTTIN
/// and silently stops it in state T, forever. Observed live 2026-08-06 when
/// the setup wizard's `sudo apt-get install imagemagick` froze on a
/// Raspberry Pi (macOS never showed it only because those wizard steps
/// don't prompt there).
///
/// This helper lends the terminal's foreground slot to the child for its
/// lifetime, then takes it back — the same dance a shell does for every
/// foreground job.
///
/// Only call it where no other thread of this process is reading stdin:
/// while the child holds the foreground, Briglia itself is background, and a
/// concurrent REPL read would SIGTTIN-stop the whole process. The setup
/// wizard and the standalone `briglia upgrade` command qualify; the in-chat
/// upgrade path (REPL/Telegram) must not use it — it never runs sudo.
enum TerminalHandoff {
    /// Launches the process and waits for it, giving it the terminal's
    /// foreground process group for the duration. Falls back to a plain
    /// run+wait when stdin is not a tty (headless daemon, CI), where job
    /// control does not apply and nothing can stop.
    static func runLendingForeground(_ process: Process) throws {
        try process.run()
        guard isatty(STDIN_FILENO) == 1 else {
            process.waitUntilExit()
            return
        }
        // Taking the foreground back afterwards happens while we are still
        // a background pgrp — that raises SIGTTOU unless ignored.
        let previousTTOU = signal(SIGTTOU, SIG_IGN)
        // Child pgid == child pid (Foundation passes pgroup 0 to
        // posix_spawn). If the child already exited this fails silently
        // and the terminal simply stays ours.
        _ = tcsetpgrp(STDIN_FILENO, process.processIdentifier)
        process.waitUntilExit()
        _ = tcsetpgrp(STDIN_FILENO, getpgrp())
        signal(SIGTTOU, previousTTOU)
    }
}
