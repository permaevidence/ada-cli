import ArgumentParser
import Foundation

let adaCLIVersion = "0.1.0-dev"

@main
struct AdaCLI: AsyncParsableCommand {
    /// Line-buffer stdout even when piped, so progress is visible in real
    /// time under `tee`, log redirection, and scripted runs.
    ///
    /// Also ignores SIGPIPE, like every long-running network process must:
    /// a write to a stale keep-alive connection (Telegram, OpenAI, a local
    /// mock) otherwise KILLS the process silently — observed live as CI's
    /// "process died early (poll=-13)" and as poll loops going dead on
    /// Linux, where the networking stack doesn't always suppress it the way
    /// Darwin's SO_NOSIGPIPE does. Ignored, broken pipes surface as ordinary
    /// EPIPE errors through the normal throwing paths.
    static func prepareIO() {
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
    }

    static let configuration = CommandConfiguration(
        commandName: "briglia",
        abstract: "Briglia — your personal AI agent, in the terminal.",
        version: adaCLIVersion,
        subcommands: [Chat.self, Setup.self, SetupAPI.self, Daemon.self, Doctor.self, Upgrade.self,
                      AdaService.self, Trigger.self, MediaSelftest.self, BundleCheck.self,
                      ToolchainCommand.self, ToolchainPrefixSelftest.self,
                      SetsidExec.self, TTYHandoffSelftest.self, BashPipelineSelftest.self,
                      BashGoldenSelftest.self, BashJobsSelftest.self,
                      TriggerSelftest.self, WatcherTriageSelftest.self, LaneSelftest.self,
                      WebAgentSelftest.self, ProviderSelftest.self, ServiceSelftest.self,
                      FsToolsSelftest.self, DeleteUserDataSelftest.self,
                      MidturnAnnotationSelftest.self, MCPSurfaceSelftest.self, StorageSelftest.self,
                      SecretStoreSelftest.self, ReleaseSigningSelftest.self,
                      VerifyEnvelopeCommand.self, TestSignEnvelopeCommand.self,
                      MindSelftest.self, SetupAPISelftest.self,
                      MigrationRunCommand.self, MigrationSelftest.self,
                      Migrate.self, MigrateProbe.self, MigrateGate.self,
                      AppChatSocketSelftest.self,
                      CommandMenuSelftest.self, BotSwitchSelftest.self,
                      EmailCalendarSelftest.self, AgentMailKeyCommand.self,
                      WebLiveTest.self],
        defaultSubcommand: Chat.self
    )
}

/// Child pid of the __setsid-exec posix_spawn fallback, for signal
/// forwarding (a C signal handler cannot capture context).
private nonisolated(unsafe) var setsidExecChildPid: pid_t = 0
private func forwardSignalToSetsidChild(_ signum: Int32) {
    // Async-signal-safe only: kill(2). The child is a session+group leader
    // (POSIX_SPAWN_SETSID), so signal its whole GROUP — forwarding to the
    // bare pid would reach the shell but miss grandchildren it spawned.
    // Fall back to the pid if the group signal fails.
    if setsidExecChildPid > 0 {
        if kill(-setsidExecChildPid, signum) != 0 {
            kill(setsidExecChildPid, signum)
        }
    }
}

/// Hidden internal trampoline: detach from the controlling terminal, then
/// exec the given program in place (same PID — Process bookkeeping, timeouts,
/// and pgrep-based tree kills in the parent keep working).
///
/// BashTools routes every model-driven shell command through this. Without
/// it, a child that prompts on /dev/tty (sudo — observed live when the Browse
/// subagent ran Playwright's Chrome installer — ssh, security(1)) writes
/// `Password:` into Briglia's own terminal and blocks the turn forever, invisible
/// to a Telegram-driven session. Worse, typed input then races byte-by-byte
/// between the prompting child and Briglia's REPL reader. Detached, such tools
/// fail fast with "no tty" and the failure surfaces to the model as ordinary
/// command output.
struct SetsidExec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__setsid-exec",
        abstract: "Internal: exec a program detached from the controlling terminal.",
        shouldDisplay: false
    )

    @Argument(parsing: .remaining)
    var argv: [String] = []

    /// Optional side channel for the parent: the pid of the DETACHED session
    /// leader, i.e. the group to kill to reach the real process tree. In the
    /// exec-in-place path that is this process; in the posix_spawn fallback
    /// it is the spawned child — whose own-session group the parent could
    /// otherwise never learn (killing the tracked pid's group only reaches
    /// this shim). Used by UserdataToolchain's timeout enforcement.
    private func reportDetachedLeader(_ pid: pid_t) {
        guard let path = ProcessInfo.processInfo.environment["BRIGLIA_SETSID_PGID_FILE"],
              !path.isEmpty else { return }
        try? "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    func run() throws {
        guard let exe = argv.first, exe.hasPrefix("/") else {
            FileHandle.standardError.write(Data(
                "briglia __setsid-exec: usage: briglia __setsid-exec -- /abs/path arg...\n".utf8))
            throw ExitCode(64)
        }
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)

        // Optional file-creation mask for the target (and everything it
        // spawns): children that write under Briglia's storage roots — the
        // WhatsApp bridge and its npm install — run with 077 so their files
        // are owner-only from creation. The variable is consumed here and
        // not passed on. Malformed values are ignored (umask unchanged).
        if let raw = ProcessInfo.processInfo.environment["BRIGLIA_CHILD_UMASK"] {
            if let value = mode_t(raw, radix: 8), value <= 0o777 { umask(value) }
            unsetenv("BRIGLIA_CHILD_UMASK")
        }

        // Start a new session, dropping the controlling terminal. The happy
        // path execs in place, so the PID the parent tracks IS the target.
        if setsid() != -1 {
            reportDetachedLeader(getpid())
            execv(exe, cargs)
            FileHandle.standardError.write(Data(
                "briglia __setsid-exec: exec \(exe) failed: \(String(cString: strerror(errno)))\n".utf8))
            Foundation.exit(127)
        }

        // setsid() fails (EPERM) when this process is already a process-group
        // leader — some spawn paths make it one. Re-spawn the target with
        // POSIX_SPAWN_SETSID (detaches in the child, where it can't fail for
        // that reason) and mirror its exit status. Tree kills in Briglia walk
        // pgrep -P descendants, so the extra hop stays killable.
        #if os(Linux)
        let setsidFlag: Int16 = 0x80          // glibc spawn.h, glibc >= 2.26
        var attr = posix_spawnattr_t()
        #else
        let setsidFlag: Int16 = 0x0400        // sys/spawn.h POSIX_SPAWN_SETSID
        var attr: posix_spawnattr_t? = nil
        #endif
        posix_spawnattr_init(&attr)
        // SETSIGDEF + empty SETSIGMASK: give the child clean signal state.
        // Raw posix_spawn otherwise inherits ignored dispositions — a child
        // that inherits SIGTERM=SIG_IGN can never be terminated by the
        // registry shutdowns that this shim forwards signals for. (Foundation
        // Process resets dispositions the same way when it spawns.)
        var defaultSigs = sigset_t()
        sigfillset(&defaultSigs)
        posix_spawnattr_setsigdefault(&attr, &defaultSigs)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setflags(
            &attr, setsidFlag | Int16(POSIX_SPAWN_SETSIGDEF) | Int16(POSIX_SPAWN_SETSIGMASK))
        let envStrings = ProcessInfo.processInfo.environment
            .filter { $0.key != "BRIGLIA_CHILD_UMASK" }
            .map { "\($0.key)=\($0.value)" }
        var cenv: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
        cenv.append(nil)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, &attr, cargs, cenv)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else {
            FileHandle.standardError.write(Data(
                "briglia __setsid-exec: spawn \(exe) failed: \(String(cString: strerror(rc)))\n".utf8))
            Foundation.exit(127)
        }
        // Forward termination signals to the detached child: a parent that
        // kills this shim (MCP/LSP registry shutdown, Process.terminate)
        // must reach the real server, or it would leak as an orphan in its
        // own session. kill(2) is async-signal-safe.
        setsidExecChildPid = pid
        reportDetachedLeader(pid)
        signal(SIGTERM, forwardSignalToSetsidChild)
        signal(SIGINT, forwardSignalToSetsidChild)
        signal(SIGHUP, forwardSignalToSetsidChild)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signum = status & 0x7f
        if signum != 0 {
            signal(signum, SIG_DFL)
            raise(signum)
            Foundation.exit(128 + signum)
        }
        Foundation.exit((status >> 8) & 0xff)
    }
}

/// Hidden regression probe for TerminalHandoff (driven by the smoke suite
/// under a real pty): spawns a child that must READ the controlling
/// terminal. Foundation puts the child in a background process group, so
/// without the foreground handoff its read is SIGTTIN-stopped forever —
/// the frozen `sudo apt-get` setup bug (2026-08-06). With the handoff the
/// read succeeds, the child echoes the line back, and this exits 0.
struct TTYHandoffSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__tty-handoff-selftest",
        abstract: "Internal: verify TerminalHandoff lends the terminal to a prompting child.",
        shouldDisplay: false
    )

    func run() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "read line && printf 'HANDOFF_GOT:%s\\n' \"$line\""]
        try TerminalHandoff.runLendingForeground(child)
        Foundation.exit(child.terminationStatus)
    }
}

/// Hidden credential broker for the `agentmail` wrapper script: prints Briglia's
/// stored AgentMail API key so the wrapper can hand it ONLY to the real
/// AgentMail binary at exec time — no ambient env injection into other bash
/// subprocesses (Codex, 2026-08-22: a shell-string heuristic is not a
/// credential boundary). Any same-user process could equally read
/// ~/.config/briglia/secrets.json (0600), so this exposes nothing new. The
/// AgentMail key is deliberately visible to the agent (CredentialCatalog:
/// only the Telegram bot token and the service keys are redacted from tool
/// output — owner decision, 2026-09-02).
struct AgentMailKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__agentmail-key",
        abstract: "Internal: print the stored AgentMail API key (used by the agentmail wrapper).",
        shouldDisplay: false
    )

    func run() throws {
        guard let key = KeychainHelper.load(key: KeychainHelper.agentMailApiKeyKey), !key.isEmpty else {
            FileHandle.standardError.write(Data("no AgentMail API key stored — run `briglia setup` (email step)\n".utf8))
            throw ExitCode(1)
        }
        print(key)
    }
}

/// Hidden installer smoke test: verify the SwiftPM resource bundle
/// (briglia-cli_briglia.bundle — bundled skills, WhatsApp bridge, toolchain scripts)
/// is deployed next to this executable. `--version` alone cannot catch a
/// missing bundle, and Bundle.module TRAPS (SIGTRAP, exit 133) on first
/// resource access — so this probes for the bundle manually before touching
/// Bundle.module, and exits with a readable error instead of a crash.
struct BundleCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle-check",
        abstract: "Verify the resource bundle is installed next to the briglia binary.",
        shouldDisplay: false
    )

    /// SwiftPM's resource artifact is named per platform: a `.bundle` on
    /// Darwin, a `.resources` directory on Linux.
    static let bundleName: String = {
        #if os(Linux)
        "briglia-cli_briglia.resources"
        #else
        "briglia-cli_briglia.bundle"
        #endif
    }()

    func run() throws {
        // argv[0] can be a bare "briglia" resolved via PATH; Bundle.main knows the
        // real executable path on both macOS and Linux (/proc/self/exe).
        let executable = (Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let bundleURL = executable.deletingLastPathComponent()
            .appendingPathComponent(Self.bundleName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            print("""
            ✖ resource bundle missing: \(bundleURL.path)
              The installer must copy \(Self.bundleName) next to the briglia binary
              (scripts/install.sh does this). Without it, skills and the
              WhatsApp bridge are unavailable and Briglia crashes on first use.
            """)
            throw ExitCode(1)
        }
        // Safe now — the bundle exists, so Bundle.module resolves.
        guard let resourceURL = Bundle.module.resourceURL,
              FileManager.default.fileExists(
                  atPath: resourceURL.appendingPathComponent("BundledSkills").path) else {
            print("✖ resource bundle found but BundledSkills is missing — corrupted install?")
            throw ExitCode(1)
        }
        print("✔ resource bundle OK: \(bundleURL.path)")
    }
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Interactive chat with Briglia (default command)."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        let session = await TerminalSession()
        try await session.runChat()
    }
}

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run Briglia headless: no local chat, messaging channels (Telegram) only."
    )

    func run() async throws {
        AdaCLI.prepareIO()
        try IdentityMigration.gateMutatingEntry()
        IdentityMigration.warnLegacyEnvironment()
        let session = await TerminalSession()
        try await session.runDaemon()
    }
}
