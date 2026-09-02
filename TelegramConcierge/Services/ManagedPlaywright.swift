import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#endif

/// Lockfile-managed Playwright MCP installation (security plan §H4.4,
/// Release C).
///
/// Until v0.2.6 the auto-registered `playwright` server was
/// `npx @playwright/mcp@latest`: every daemon start re-resolved "latest"
/// against the npm registry and ran whatever it served, unaudited. The
/// managed install replaces that with a tree pinned by the committed
/// `Resources/MCPBundles/playwright/package-lock.json` (exact versions and
/// SHA-512 integrity for every package), installed once per lockfile into
/// an immutable versioned directory and referenced from `mcp.json` by an
/// atomic config write:
///
///     ~/.local/share/briglia/mcp/
///         playwright-install.lock          flock, held for the whole bootstrap
///         playwright-bootstrap.json        last outcome (doctor)
///         playwright.staging-<uuid>/       build in progress (orphans removed)
///         playwright-<lockfileHash>/       immutable, verified install
///             .briglia-complete            marker, written last, holds the hash
///             package.json, package-lock.json, node_modules/…
///         playwright.corrupt-<uuid>/       quarantined failed verification
///
/// Transaction (one installation lock, `npm ci` inside it):
///   1. lock → remove orphan staging/corrupt directories;
///   2. an existing `playwright-<hash>` is VERIFIED (marker + `initialize`
///      handshake) and reused, or quarantined and rebuilt — never referenced
///      while unverified;
///   3. staging: manifests copied in, `npm ci --ignore-scripts` under a
///      bounded timeout in its own process group (terminated, reaped and
///      verified gone on timeout), executable present, handshake answers,
///      completion marker written last;
///   4. publish: every file and directory fsynced bottom-up, `rename` to the
///      immutable name, parent directory fsynced;
///   5. the switch is ONE atomic write of `mcp.json` that changes only the
///      playwright entry (`MCPRegistry.updateManagedPlaywrightEntry`). Until
///      it lands, the previous entry keeps working; if it never lands, nothing
///      was lost.
/// Valid immutable installations are never auto-deleted: an external edit
/// of `mcp.json` (the agent through file tools, or a human) may reference any
/// of them at any time. `doctor` lists unreferenced versions.
///
/// The Playwright BROWSER is not part of the pinned tree: it lives in
/// Playwright's own cache and is installed by the server's `browser_install`
/// tool on first use, exactly as before.
enum ManagedPlaywright {
    static let serverName = "playwright"
    static let legacyCommand = "npx"
    static let legacyArguments = ["@playwright/mcp@latest"]
    static let markerPrefix = "playwright@"
    static let completionMarkerName = ".briglia-complete"
    static let cliRelativePath = "node_modules/@playwright/mcp/cli.js"
    static let packageRelativePath = "node_modules/@playwright/mcp/package.json"
    static let bundleRelativePath = "MCPBundles/playwright"
    /// The tool every @playwright/mcp release exposes; its presence in
    /// `tools/list` is what distinguishes "a server answered" from "the
    /// Playwright server answered".
    static let requiredTool = "browser_navigate"
    static let npmTimeout: TimeInterval = 600
    /// playwright-core's `engines.node`.
    static let minimumNodeMajor = 20

    // MARK: - Manifests

    struct Manifests: Sendable {
        let packageJSON: Data
        let packageLock: Data
        /// First 16 hex characters of SHA-256(package-lock.json): the
        /// immutable directory name suffix and the `managed` marker.
        let lockfileHash: String

        init(packageJSON: Data, packageLock: Data) {
            self.packageJSON = packageJSON
            self.packageLock = packageLock
            self.lockfileHash = Manifests.hash(of: packageLock)
        }

        static func hash(of lock: Data) -> String {
            String(SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined().prefix(16))
        }

        static func load(from directory: URL) throws -> Manifests {
            let pkg = try Data(contentsOf: directory.appendingPathComponent("package.json"))
            let lock = try Data(contentsOf: directory.appendingPathComponent("package-lock.json"))
            return Manifests(packageJSON: pkg, packageLock: lock)
        }

        /// The manifests shipped in the resource bundle next to the binary.
        /// Probes for the bundle first: `Bundle.module` traps when it is
        /// missing, and doctor/bundle-check must report, not crash.
        static func bundled() throws -> Manifests {
            let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
                .resolvingSymlinksInPath()
            let bundleURL = executable.deletingLastPathComponent().appendingPathComponent(BundleCheck.bundleName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                throw ManagedError("resource bundle missing next to the binary (\(bundleURL.path))")
            }
            guard let resourceURL = Bundle.module.resourceURL else {
                throw ManagedError("resource bundle has no resource directory")
            }
            return try load(from: resourceURL.appendingPathComponent(bundleRelativePath, isDirectory: true))
        }

        /// The pinned @playwright/mcp version named by the lockfile.
        var pinnedVersion: String? {
            guard let root = try? JSONSerialization.jsonObject(with: packageLock) as? [String: Any],
                  let packages = root["packages"] as? [String: Any],
                  let mcp = packages["node_modules/@playwright/mcp"] as? [String: Any] else { return nil }
            return mcp["version"] as? String
        }

        /// Lockfile sanity (bundle-check and the selftest): lockfile v3, every
        /// dependency resolved with an integrity hash from the public registry,
        /// no install scripts (we run `npm ci --ignore-scripts`; a tree that
        /// needed one would be silently broken).
        func lockfileProblems() -> [String] {
            var problems: [String] = []
            guard let root = try? JSONSerialization.jsonObject(with: packageLock) as? [String: Any] else {
                return ["package-lock.json is not a JSON object"]
            }
            if (root["lockfileVersion"] as? Int) != 3 { problems.append("lockfileVersion is not 3") }
            guard let packages = root["packages"] as? [String: Any] else { return problems + ["no packages map"] }
            if packages["node_modules/@playwright/mcp"] == nil { problems.append("@playwright/mcp missing from the lockfile") }
            for (path, raw) in packages.sorted(by: { $0.key < $1.key }) where !path.isEmpty {
                guard let entry = raw as? [String: Any] else { problems.append("\(path): malformed"); continue }
                let resolved = entry["resolved"] as? String ?? ""
                if !resolved.hasPrefix("https://registry.npmjs.org/") { problems.append("\(path): resolved is not the public registry (\(resolved))") }
                if !(entry["integrity"] as? String ?? "").hasPrefix("sha512-") { problems.append("\(path): no sha512 integrity") }
                if (entry["hasInstallScript"] as? Bool) == true { problems.append("\(path): has an install script (we run npm ci --ignore-scripts)") }
                if (entry["link"] as? Bool) == true { problems.append("\(path): is a link") }
            }
            return problems
        }
    }

    struct ManagedError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Layout

    struct Layout: Sendable {
        let mcpRoot: URL
        init(dataRoot: URL = StoragePaths.dataRoot) {
            mcpRoot = dataRoot.appendingPathComponent("mcp", isDirectory: true)
        }
        var installLock: URL { mcpRoot.appendingPathComponent("playwright-install.lock") }
        var statusFile: URL { mcpRoot.appendingPathComponent("playwright-bootstrap.json") }
        func versionDirectory(hash: String) -> URL {
            mcpRoot.appendingPathComponent("playwright-\(hash)", isDirectory: true)
        }
        func cliPath(hash: String) -> String {
            versionDirectory(hash: hash).appendingPathComponent(cliRelativePath).path
        }
        func stagingDirectory() -> URL {
            mcpRoot.appendingPathComponent("playwright.staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        }
        func corruptDirectory() -> URL {
            mcpRoot.appendingPathComponent("playwright.corrupt-\(UUID().uuidString.lowercased())", isDirectory: true)
        }
        /// `playwright-<16 hex>` → the hash; nil for anything else.
        static func hash(fromDirectoryName name: String) -> String? {
            guard name.hasPrefix("playwright-") else { return nil }
            let hash = String(name.dropFirst("playwright-".count))
            guard hash.count == 16, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
            return hash
        }
        /// Every immutable version directory present (verified or not).
        func installedHashes() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: mcpRoot.path)) ?? [])
                .compactMap(Layout.hash(fromDirectoryName:)).sorted()
        }
        func leftovers() -> (staging: [String], corrupt: [String]) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: mcpRoot.path)) ?? []
            return (names.filter { $0.hasPrefix("playwright.staging-") }.sorted(),
                    names.filter { $0.hasPrefix("playwright.corrupt-") }.sorted())
        }
    }

    // MARK: - Entry shapes

    /// How the `playwright` entry of `mcp.json` relates to the managed install.
    enum EntryShape: Equatable {
        /// No entry.
        case absent
        /// The auto-registered legacy shape (`npx @playwright/mcp@latest`),
        /// enabled: switched to the managed install once one is verified.
        case legacyAuto
        /// A managed entry whose command/args match its marker exactly.
        case managed(hash: String)
        /// Carries a managed marker but the command/args were edited by hand
        /// (or the marker is malformed): left alone, reported by doctor.
        case managedEdited
        /// A user-authored entry (own command/args): never touched.
        case userAuthored
        /// Disabled in mcp.json (any shape): left alone, no install is made.
        case disabled
    }

    static func managedMarker(hash: String) -> String { markerPrefix + hash }

    static func hash(fromMarker marker: String) -> String? {
        guard marker.hasPrefix(markerPrefix) else { return nil }
        let hash = String(marker.dropFirst(markerPrefix.count))
        guard hash.count == 16, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return hash
    }

    /// The exact command/args of a managed entry: `node <cli.js>`. `node` is
    /// deliberately bare — resolved through the augmented MCP PATH at spawn
    /// time (`~/.local/bin` first, where `NodeInstaller` links its copy) —
    /// so a Node reinstall or a Homebrew upgrade never strands the entry.
    static func managedInvocation(hash: String, layout: Layout) -> (command: String, arguments: [String]) {
        ("node", [layout.cliPath(hash: hash)])
    }

    static func shape(of config: MCPServerConfig?, layout: Layout) -> EntryShape {
        guard let config else { return .absent }
        if config.disabled { return .disabled }
        if let marker = config.managed {
            guard let hash = hash(fromMarker: marker) else { return .managedEdited }
            let expected = managedInvocation(hash: hash, layout: layout)
            if config.command == expected.command && config.arguments == expected.arguments {
                return .managed(hash: hash)
            }
            return .managedEdited
        }
        if config.command == legacyCommand && config.arguments == legacyArguments {
            return .legacyAuto
        }
        return .userAuthored
    }

    /// A managed entry for `hash`, keeping everything the existing entry
    /// carried that is not the invocation (env, secretRefs, description,
    /// disabled flag).
    static func managedConfig(hash: String, layout: Layout, basedOn existing: MCPServerConfig?) -> MCPServerConfig {
        let invocation = managedInvocation(hash: hash, layout: layout)
        return MCPServerConfig(
            name: serverName,
            command: invocation.command,
            arguments: invocation.arguments,
            environment: existing?.environment ?? [:],
            disabled: existing?.disabled ?? false,
            secretRefs: existing?.secretRefs ?? [],
            description: existing?.description ?? defaultDescription,
            managed: managedMarker(hash: hash)
        )
    }

    static let defaultDescription = "Browser automation (drives a local browser for the Browse subagent)"

    /// The legacy auto-registered entry (what pre-0.2.6 fresh installs wrote).
    /// Written today only by profile import for a managed marker that has no
    /// local installation yet — the next start switches it.
    static func legacyConfig(basedOn existing: MCPServerConfig?) -> MCPServerConfig {
        MCPServerConfig(
            name: serverName,
            command: legacyCommand,
            arguments: legacyArguments,
            environment: existing?.environment ?? [:],
            disabled: existing?.disabled ?? false,
            secretRefs: existing?.secretRefs ?? [],
            description: existing?.description ?? defaultDescription,
            managed: nil
        )
    }

    // MARK: - Context (production values; the selftest substitutes fakes)

    enum CrashPoint: String, CaseIterable, Sendable {
        case beforeInstall = "before-install"
        case afterInstall = "after-install"
        case afterRename = "after-rename"
        case afterParentFsync = "after-parent-fsync"
        case afterConfigWrite = "after-config-write"
    }

    struct Context: Sendable {
        var layout: Layout
        var manifests: Manifests
        /// Directory holding `node` and `npm`.
        var nodeDirectory: String
        /// Environment for `npm ci` and the verification handshake (the MCP
        /// base environment with `nodeDirectory` first on PATH).
        var environment: [String: String]
        var npmTimeout: TimeInterval = ManagedPlaywright.npmTimeout
        var handshakeTimeout: TimeInterval = 30
        var crashPoint: CrashPoint? = nil
        var log: @Sendable (String) -> Void = { NSLog("ManagedPlaywright: %@", $0) }

        static func environment(nodeDirectory: String, base: [String: String]) -> [String: String] {
            var env = base
            env["PATH"] = nodeDirectory + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            // npm hygiene: no update banners, no funding notices, non-interactive.
            env["npm_config_update_notifier"] = "false"
            env["NO_UPDATE_NOTIFIER"] = "1"
            env["npm_config_fund"] = "false"
            env["npm_config_audit"] = "false"
            env["CI"] = "1"
            return env
        }
    }

    static func crash(_ point: CrashPoint, if context: Context) {
        guard context.crashPoint == point else { return }
        context.log("crash injection at \(point.rawValue)")
        _exit(137)
    }

    // MARK: - Node resolution

    /// The directory of a usable Node (≥ `minimumNodeMajor`) next to which
    /// `npm` lives, or nil with the reason.
    static func resolveNodeDirectory(preferred: String? = nil) -> (directory: String?, reason: String?) {
        var candidates: [String] = []
        if let preferred { candidates.append(preferred) }
        if let detected = NodeInstaller.detectNode() { candidates.append(detected) }
        var reasons: [String] = []
        for node in candidates {
            let dir = URL(fileURLWithPath: node).deletingLastPathComponent().path
            let probe = runDetached(executable: node, arguments: ["--version"], cwd: nil,
                                    environment: ProcessInfo.processInfo.environment, timeout: 15)
            let version = probe.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard probe.exitCode == 0, let major = Int(version.dropFirst().split(separator: ".").first ?? "") else {
                reasons.append("\(node): does not answer --version"); continue
            }
            guard major >= minimumNodeMajor else {
                reasons.append("\(node) is \(version); Playwright needs Node \(minimumNodeMajor) or newer"); continue
            }
            guard FileManager.default.isExecutableFile(atPath: dir + "/npm") else {
                reasons.append("\(dir)/npm missing next to node"); continue
            }
            return (dir, nil)
        }
        return (nil, reasons.isEmpty ? "node not found" : reasons.joined(separator: "; "))
    }

    // MARK: - Install transaction

    enum InstallOutcome: Equatable, Sendable {
        /// `playwright-<hash>` is verified (freshly installed or reused).
        case ready(hash: String, reused: Bool)
        /// Another live process holds the installation lock; nothing was done.
        case skipped(String)
        /// The install could not be completed; the previous state is intact.
        case failed(String)
    }

    /// The whole transaction under the installation lock. Never touches
    /// `mcp.json` — the caller performs the switch through `MCPRegistry`.
    static func ensureInstalled(context: Context) async -> InstallOutcome {
        let layout = context.layout
        let hash = context.manifests.lockfileHash
        do {
            try PrivateStorage.ensureDirectory(layout.mcpRoot)
        } catch {
            return .failed("cannot create \(layout.mcpRoot.path): \(error)")
        }
        let lock: InstallLock
        do {
            guard let acquired = try InstallLock.tryAcquire(layout.installLock) else {
                return .skipped("installation lock held by another process")
            }
            lock = acquired
        } catch {
            return .failed("installation lock: \(error)")
        }
        defer { lock.release() }

        // Orphans: with the lock held for the whole bootstrap, any staging
        // directory belongs to a dead holder; corrupt directories were
        // quarantined by an earlier start. Neither is ever referenced.
        for name in removeLeftovers(layout: layout) { context.log("removed leftover \(name)") }

        crash(.beforeInstall, if: context)

        // Reuse rule: an existing version directory is verified, never rebuilt.
        let versionDir = layout.versionDirectory(hash: hash)
        if FileManager.default.fileExists(atPath: versionDir.path) {
            if let problem = await verify(directory: versionDir, expectedHash: hash, context: context) {
                context.log("existing \(versionDir.lastPathComponent) failed verification (\(problem)) — quarantining")
                let corrupt = layout.corruptDirectory()
                guard rename(versionDir.path, corrupt.path) == 0 else {
                    return .failed("cannot quarantine \(versionDir.lastPathComponent): \(String(cString: strerror(errno)))")
                }
                do { try PrivateStorage.fsyncDirectory(layout.mcpRoot.path) } catch {
                    return .failed("fsync after quarantine: \(error)")
                }
            } else {
                return .ready(hash: hash, reused: true)
            }
        }

        // Staging build.
        let staging = layout.stagingDirectory()
        func abandon(_ reason: String) -> InstallOutcome {
            try? FileManager.default.removeItem(at: staging)
            return .failed(reason)
        }
        do {
            try PrivateStorage.ensureDirectory(staging)
            try PrivateStorage.writeAtomically(context.manifests.packageJSON, to: staging.appendingPathComponent("package.json"))
            try PrivateStorage.writeAtomically(context.manifests.packageLock, to: staging.appendingPathComponent("package-lock.json"))
        } catch {
            return abandon("staging: \(error)")
        }
        let npm = context.nodeDirectory + "/npm"
        guard FileManager.default.isExecutableFile(atPath: npm) else {
            return abandon("npm not found at \(npm)")
        }
        var env = context.environment
        // Everything npm creates lands under the data root: owner-only from
        // creation (the trampoline applies the umask and drops the variable).
        env["BRIGLIA_CHILD_UMASK"] = "077"
        let run = runDetached(
            executable: npm,
            arguments: ["ci", "--ignore-scripts", "--omit=dev", "--no-audit", "--no-fund", "--no-progress", "--loglevel=error"],
            cwd: staging, environment: env, timeout: context.npmTimeout)
        guard run.exitCode == 0 else {
            let tail = run.output.split(separator: "\n").suffix(6).joined(separator: " | ")
            let detail = run.exitCode == 124 ? "npm ci timed out after \(Int(context.npmTimeout))s" : "npm ci exited \(run.exitCode)"
            let group = run.processGroupVerifiedGone == false ? " (process group could not be confirmed gone)" : ""
            return abandon("\(detail)\(group): \(tail)")
        }
        if let problem = await verify(directory: staging, expectedHash: nil, context: context) {
            return abandon("staged install failed verification: \(problem)")
        }
        do {
            try PrivateStorage.writeAtomically(Data((hash + "\n").utf8), to: staging.appendingPathComponent(completionMarkerName))
        } catch {
            return abandon("completion marker: \(error)")
        }

        crash(.afterInstall, if: context)

        // Publish: durable tree, then the atomic rename, then the parent.
        do {
            try fsyncTree(staging.path)
        } catch {
            return abandon("fsync of the staged tree: \(error)")
        }
        guard rename(staging.path, versionDir.path) == 0 else {
            return abandon("cannot publish \(versionDir.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        crash(.afterRename, if: context)
        do {
            try PrivateStorage.fsyncDirectory(layout.mcpRoot.path)
        } catch {
            return .failed("fsync after publish: \(error)")
        }
        crash(.afterParentFsync, if: context)
        return .ready(hash: hash, reused: false)
    }

    /// Removes orphan staging and quarantined directories (lock must be held).
    /// Immutable `playwright-<hash>` directories are never touched.
    @discardableResult
    static func removeLeftovers(layout: Layout) -> [String] {
        let leftovers = layout.leftovers()
        var removed: [String] = []
        for name in leftovers.staging + leftovers.corrupt {
            let url = layout.mcpRoot.appendingPathComponent(name)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(name) }
        }
        return removed
    }

    // MARK: - Verification

    /// Nil when the tree at `directory` is a usable Playwright install:
    /// completion marker (when `expectedHash` is given) carrying the hash,
    /// the pinned package present at the pinned version, the executable
    /// present, and a live `initialize` handshake whose `tools/list` includes
    /// `browser_navigate`. Otherwise the reason.
    static func verify(directory: URL, expectedHash: String?, context: Context) async -> String? {
        let fm = FileManager.default
        if let expectedHash {
            let marker = directory.appendingPathComponent(completionMarkerName)
            guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
                return "no completion marker"
            }
            guard text.trimmingCharacters(in: .whitespacesAndNewlines) == expectedHash else {
                return "completion marker names another lockfile"
            }
        }
        let cli = directory.appendingPathComponent(cliRelativePath).path
        guard fm.fileExists(atPath: cli) else { return "\(cliRelativePath) missing" }
        if let pinned = context.manifests.pinnedVersion {
            guard let data = fm.contents(atPath: directory.appendingPathComponent(packageRelativePath).path),
                  let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = pkg["version"] as? String else {
                return "installed package.json unreadable"
            }
            guard version == pinned else { return "installed @playwright/mcp \(version) is not the pinned \(pinned)" }
        }
        let config = MCPServerConfig(name: "playwright-verify", command: context.nodeDirectory + "/node", arguments: [cli])
        let client = MCPClient(config: config, resolvedEnvironment: context.environment)
        do {
            try await client.start()
            try await client.initialize(timeout: context.handshakeTimeout)
        } catch {
            await client.shutdown()
            return "handshake failed: \(error)"
        }
        let tools = await client.listedTools
        await client.shutdown()
        guard tools.contains(where: { $0.toolName == requiredTool }) else {
            return "server answered but exposes no \(requiredTool) (\(tools.count) tools)"
        }
        return nil
    }

    /// Bottom-up durability of a staged tree: every regular file, then every
    /// directory deepest-first, the root last. Symlinks are skipped (their
    /// entries are covered by their directory's fsync).
    static func fsyncTree(_ root: String) throws {
        let fm = FileManager.default
        var files: [String] = []
        var dirs: [(path: String, depth: Int)] = [(root, 0)]
        func walk(_ dir: String, depth: Int) throws {
            for name in try fm.contentsOfDirectory(atPath: dir) {
                let path = dir + "/" + name
                var st = stat()
                guard lstat(path, &st) == 0 else { throw ManagedError("lstat \(path): \(String(cString: strerror(errno)))") }
                let fmt = st.st_mode & S_IFMT
                if fmt == S_IFDIR {
                    dirs.append((path, depth + 1))
                    try walk(path, depth: depth + 1)
                } else if fmt == S_IFREG {
                    files.append(path)
                }
            }
        }
        try walk(root, depth: 0)
        for path in files { try fsyncPath(path) }
        for entry in dirs.sorted(by: { $0.depth > $1.depth }) { try fsyncPath(entry.path) }
    }

    private static func fsyncPath(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ManagedError("open \(path): \(String(cString: strerror(errno)))") }
        let rc = fsync(fd)
        let code = errno
        close(fd)
        guard rc == 0 else { throw ManagedError("fsync \(path): \(String(cString: strerror(code)))") }
    }

    // MARK: - Installation lock

    final class InstallLock {
        private var fd: Int32
        private init(fd: Int32) { self.fd = fd }

        /// Exclusive, non-blocking. Nil when another process holds it.
        static func tryAcquire(_ url: URL) throws -> InstallLock? {
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw ManagedError("cannot open \(url.path): \(String(cString: strerror(errno)))")
            }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                close(fd)
                if code == EWOULDBLOCK || code == EAGAIN { return nil }
                throw ManagedError("flock \(url.path): \(String(cString: strerror(code)))")
            }
            return InstallLock(fd: fd)
        }

        func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }

        deinit { release() }
    }

    // MARK: - Detached process runner (own process group, bounded)

    struct RunResult {
        let exitCode: Int32
        let output: String
        /// After a timeout: whether the child's process group was confirmed
        /// gone (`kill(-pgid, 0)` → ESRCH) before the runner returned. Nil
        /// when no timeout occurred.
        let processGroupVerifiedGone: Bool?
    }

    /// Runs `executable` through the `__setsid-exec` trampoline so the whole
    /// tree is one session/process group; on timeout SIGTERM, a short grace,
    /// SIGKILL, `waitpid` of the direct child, then the group is polled until
    /// `kill(-pgid, 0)` fails with ESRCH (a `waitpid` cannot reap
    /// grandchildren). Mirrors `UserdataToolchain.run` with an explicit
    /// environment and the group verification the plan requires.
    static func runDetached(executable: String, arguments: [String], cwd: URL?,
                            environment: [String: String], timeout: TimeInterval) -> RunResult {
        let process = Process()
        let (exe, launchArgs) = BashTools.detachedInvocation(executable: executable, arguments: arguments)
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = launchArgs
        if let cwd { process.currentDirectoryURL = cwd }
        var env = environment
        let pgidFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "briglia-playwright-pgid-\(UUID().uuidString)")
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
        } catch {
            return RunResult(exitCode: 127, output: "launch failed: \(error.localizedDescription)", processGroupVerifiedGone: nil)
        }
        let reader = Thread { data = pipe.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let pid = process.processIdentifier
        func leaderPid() -> Int32? {
            guard let text = try? String(contentsOfFile: pgidFile.path, encoding: .utf8),
                  let leader = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), leader > 0 else { return nil }
            return leader
        }
        func signalTree(_ sig: Int32) {
            if let leader = leaderPid() { kill(-leader, sig) }
            if kill(-pid, sig) != 0 { kill(pid, sig) }
        }
        func groupGone() -> Bool {
            !processGroupHasLiveMembers(leaderPid() ?? pid)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            signalTree(SIGTERM)
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { signalTree(SIGKILL) }
            process.waitUntilExit()
            signalTree(SIGKILL)
            let groupDeadline = Date().addingTimeInterval(5)
            var gone = groupGone()
            while !gone && Date() < groupDeadline {
                Thread.sleep(forTimeInterval: 0.05)
                signalTree(SIGKILL)
                gone = groupGone()
            }
            let readerDeadline = Date().addingTimeInterval(5)
            while reader.isExecuting && Date() < readerDeadline { Thread.sleep(forTimeInterval: 0.05) }
            let captured = reader.isExecuting
                ? "(output unavailable — a straggler still holds the pipe)"
                : (String(data: data, encoding: .utf8) ?? "")
            return RunResult(exitCode: 124, output: "timed out after \(Int(timeout))s\n" + captured,
                             processGroupVerifiedGone: gone)
        }
        // Leader exited: bounded wait for the pipe (a detached child could
        // hold it), then kill whatever is left in the group.
        while reader.isExecuting && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        var stragglers = false
        if reader.isExecuting {
            stragglers = true
            signalTree(SIGTERM)
            let grace = Date().addingTimeInterval(2)
            while reader.isExecuting && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if reader.isExecuting {
                signalTree(SIGKILL)
                let finalJoin = Date().addingTimeInterval(5)
                while reader.isExecuting && Date() < finalJoin { Thread.sleep(forTimeInterval: 0.05) }
            }
        }
        process.waitUntilExit()
        if reader.isExecuting {
            return RunResult(exitCode: 124, output: "the command exited but a detached descendant still holds its output pipe — process group killed, output unavailable",
                             processGroupVerifiedGone: groupGone())
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if stragglers {
            let status = process.terminationStatus
            return RunResult(exitCode: status == 0 ? 124 : status,
                             output: text + "\n(detached descendant processes outlived the command and were killed — treated as failure)",
                             processGroupVerifiedGone: groupGone())
        }
        return RunResult(exitCode: process.terminationStatus, output: text, processGroupVerifiedGone: nil)
    }

    /// True while any NON-zombie process belongs to `pgid`. `kill(-pgid, 0)`
    /// alone also counts zombies: in a container whose PID 1 does not reap
    /// (GitHub's Swift container), a killed grandchild of npm stays a zombie
    /// forever and the group would never read as gone. On Linux `/proc` gives
    /// the state; elsewhere launchd reaps orphans and the kill probe suffices.
    static func processGroupHasLiveMembers(_ pgid: Int32) -> Bool {
        #if os(Linux)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") {
            var scanned = false
            for name in names where Int32(name) != nil {
                guard let stat = try? String(contentsOfFile: "/proc/\(name)/stat", encoding: .utf8),
                      let close = stat.range(of: ")", options: .backwards) else { continue }
                scanned = true
                // After the parenthesised comm: state ppid pgrp …
                let fields = stat[close.upperBound...].split(separator: " ")
                guard fields.count > 2, fields[0] != "Z" else { continue }
                if Int32(fields[2]) == pgid { return true }
            }
            if scanned { return false }
        }
        #endif
        return !(kill(-pgid, 0) == -1 && errno == ESRCH)
    }

    // MARK: - Bootstrap status (doctor)

    struct BootstrapStatus: Codable, Equatable {
        var at: Date
        /// `ready` | `skipped` | `failed` | `left-alone`
        var outcome: String
        var hash: String?
        var reason: String?
    }

    static func recordStatus(_ status: BootstrapStatus, layout: Layout) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(status) else { return }
        try? PrivateStorage.ensureDirectory(layout.mcpRoot)
        try? PrivateStorage.writeAtomically(data, to: layout.statusFile)
    }

    static func readStatus(layout: Layout) -> BootstrapStatus? {
        guard let data = FileManager.default.contents(atPath: layout.statusFile.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BootstrapStatus.self, from: data)
    }

    // MARK: - Doctor

    struct Finding {
        let text: String
        let problem: Bool
        let hint: String?
    }

    /// Read-only report for `briglia doctor`: the entry's shape, whether the
    /// referenced install carries its marker, unreferenced and leftover
    /// directories, the last bootstrap outcome.
    static func doctorFindings(configs: [MCPServerConfig], layout: Layout,
                               bundledHash: String?) -> [Finding] {
        var out: [Finding] = []
        let entry = configs.first { $0.name == serverName }
        let installed = layout.installedHashes()
        var referenced: String? = nil
        switch shape(of: entry, layout: layout) {
        case .absent:
            out.append(Finding(text: "playwright: not registered (the Browse subagent is unavailable)", problem: false, hint: nil))
        case .legacyAuto:
            out.append(Finding(text: "playwright: legacy `npx @playwright/mcp@latest` entry — switched to the pinned managed install at the next successful start",
                               problem: false, hint: nil))
        case .managed(let hash):
            referenced = hash
            let marker = layout.versionDirectory(hash: hash).appendingPathComponent(completionMarkerName)
            let ok = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == hash
            let current = bundledHash == nil || bundledHash == hash
            out.append(Finding(text: "playwright: managed install playwright-\(hash)\(current ? "" : " (this build pins \(bundledHash ?? "?") — updated at the next successful start)")",
                               problem: !ok,
                               hint: ok ? nil : "the referenced directory is missing or incomplete — start briglia once, the bootstrap rebuilds or re-points it"))
        case .managedEdited:
            out.append(Finding(text: "playwright: managed marker present but command/args were edited by hand — left alone (remove the `managed` field to make that permanent)", problem: false, hint: nil))
        case .userAuthored:
            out.append(Finding(text: "playwright: user-authored entry (\(entry?.command ?? "") \(entry?.arguments.joined(separator: " ") ?? "")) — not managed", problem: false, hint: nil))
        case .disabled:
            out.append(Finding(text: "playwright: disabled in mcp.json", problem: false, hint: nil))
        }
        let unreferenced = installed.filter { $0 != referenced }
        if !unreferenced.isEmpty {
            out.append(Finding(text: "unreferenced managed versions kept (never auto-deleted): \(unreferenced.map { "playwright-\($0)" }.joined(separator: ", ")) — remove by hand under \(layout.mcpRoot.path) if unwanted",
                               problem: false, hint: nil))
        }
        let leftovers = layout.leftovers()
        if !leftovers.staging.isEmpty || !leftovers.corrupt.isEmpty {
            out.append(Finding(text: "leftover directories removed at the next start: \((leftovers.staging + leftovers.corrupt).joined(separator: ", "))",
                               problem: false, hint: nil))
        }
        if let status = readStatus(layout: layout) {
            let fmt = ISO8601DateFormatter()
            let reason = status.reason.map { " — \($0)" } ?? ""
            out.append(Finding(text: "last bootstrap \(fmt.string(from: status.at)): \(status.outcome)\(reason)",
                               problem: status.outcome == "failed",
                               hint: status.outcome == "failed" ? "the previous entry keeps working; the next start retries" : nil))
        }
        return out
    }
}
