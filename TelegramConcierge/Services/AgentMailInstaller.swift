import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Transactional, cancellable AgentMail CLI installer (plan §6.6)
//
// The published pair is `~/.local/bin/agentmail` (the key-broker wrapper) and
// the immutable versioned binary it points at
// (`agentmail-bin-<version>-<sha256[0:12]>`). The wrapper replacement is the
// SINGLE commit point; the transaction metadata (`agentmail.tx.json`) is
// three-state — staged → committing → committed (or rolled_back) — with
// `committing` persisted BEFORE the swap so recovery inspects the live
// wrapper instead of trusting the state. One exclusive, symlink-safe flock
// (`.agentmail.lock`) serializes every install and repair path; doctor
// never takes it and only reports.

extension AgentMailService {
    static let wrapperName = "agentmail"
    static let legacyBinaryName = "agentmail-bin"
    static let transactionFileName = "agentmail.tx.json"
    static let installerLockName = ".agentmail.lock"
    static let stagingPrefix = ".agentmail-staging-"

    /// Selftest seam: the install directory (production: ~/.local/bin).
    nonisolated(unsafe) static var installDirectoryOverride: URL?
    static var installDirectory: URL {
        installDirectoryOverride
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin", isDirectory: true)
    }

    /// Selftest seam: replaces the release lookup + downloads. Returns the
    /// archive bytes, the checksum file bytes, the version and asset name.
    typealias DownloadFixture = (version: String, asset: String, archive: Data, checksums: Data)
    nonisolated(unsafe) static var downloadOverride: ((_ progress: (@Sendable (String) -> Void)?) async throws -> DownloadFixture)?
    /// Selftest seam: crash injection points, by name (`SIGKILL`s self).
    nonisolated(unsafe) static var crashPoint: String?
    /// Selftest seam: the exact path of the `briglia` binary the wrapper calls.
    nonisolated(unsafe) static var brigliaPathOverride: String?

    /// How the installer runs its children (tar, xattr, smoke tests). The
    /// default is the plain process runner (wizard, setup-api, UT app);
    /// quick setup passes the journaled `SetupJobRunner`.
    struct ChildRunner {
        var run: (_ command: [String], _ timeoutSeconds: Int, _ label: String) async -> (ok: Bool, stdout: String?, detail: String?)

        static let plain = ChildRunner { command, timeout, _ in
            let r = await GoogleWorkspaceService.runProcessAsync(
                executable: command[0], args: Array(command.dropFirst()), timeoutSeconds: timeout)
            return (r.failureDetail == nil, r.stdout, r.failureDetail)
        }

        static func journaled(_ runner: SetupJobRunner, row: String) -> ChildRunner {
            ChildRunner { command, timeout, label in
                let result = await runner.run(.init(row: row, command: command, mode: .detached,
                                                    timeout: TimeInterval(timeout), label: label))
                return (result.ok, result.lastLines.joined(separator: "\n"), result.failureReason)
            }
        }
    }

    struct PreviousWrapper: Codable, Equatable {
        var bytesB64: String
        var sha256: String
        var mode: Int
    }

    struct Transaction: Codable, Equatable {
        var version = 1
        var state: String   // staged | committing | committed | rolled_back
        var newBinary: String
        var newSHA256: String
        var newWrapperSHA256: String
        var previousWrapper: PreviousWrapper?
        var previousBinary: String?
        var startedAt: Date
    }

    struct InstallerBusy: Error {}

    // MARK: Paths and validation

    static var transactionURL: URL { installDirectory.appendingPathComponent(transactionFileName) }
    static var wrapperURL: URL { installDirectory.appendingPathComponent(wrapperName) }
    static var lockURL: URL { installDirectory.appendingPathComponent(installerLockName) }

    static let versionedNameRegex = try! NSRegularExpression(pattern: "^agentmail-bin(-[A-Za-z0-9._]+-[0-9a-f]{12})?$")

    /// A plain basename owned by the transaction: no `/`, not `.`/`..`,
    /// matches the versioned pattern. Existence checks are the caller's.
    static func validBasename(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
        return versionedNameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func versionedName(version: String, sha256: String) -> String {
        let safe = version.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }
        return "agentmail-bin-\(safe.isEmpty ? "unknown" : safe)-\(sha256.prefix(12))"
    }

    /// `exec '<path>' "$@"` target of a wrapper script; nil when the bytes
    /// are not a wrapper of ours.
    static func wrapperTarget(_ bytes: Data) -> String? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("exec '") else { continue }
            let rest = t.dropFirst("exec '".count)
            guard let end = rest.firstIndex(of: "'") else { return nil }
            return String(rest[..<end])
        }
        return nil
    }

    /// Is Briglia's key-brokered install complete: the `agentmail` wrapper
    /// (verified by content), executable, and its target exists as a
    /// regular file. A bare `agentmail` binary from npm/brew does NOT count
    /// (no broker ⇒ cannot authenticate).
    static func agentMailBrokerInstalled() -> Bool {
        let wrapper = wrapperURL
        guard isBrokerWrapper(at: wrapper), let data = try? Data(contentsOf: wrapper),
              let target = wrapperTarget(data) else { return false }
        var st = stat()
        guard lstat(target, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: target)
    }

    private static func brigliaPath() -> String {
        brigliaPathOverride ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().path
    }

    // MARK: Lock

    /// Exclusive, symlink-safe installer lock. `nil` = busy.
    private static func openInstallerLock() throws -> Int32? {
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "briglia.agentmail", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "cannot open \(lockURL.path): \(String(cString: strerror(errno))) (a symlink or non-regular file at that path is refused)"])
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw NSError(domain: "briglia.agentmail", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(lockURL.path) is not a regular file — refusing"])
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Read-only probe for doctor: is an installer or repair running now?
    static func installerLockBusy() -> Bool {
        let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }

    static func withInstallerLock<T>(_ body: () async throws -> T) async throws -> T {
        guard let fd = try openInstallerLock() else { throw InstallerBusy() }
        defer { close(fd) }   // releases the flock
        return try await body()
    }

    // MARK: Durable helpers

    private static func fsyncDir() throws { try PrivateStorage.fsyncDirectory(installDirectory.path) }

    private static func writeTransaction(_ tx: Transaction) throws {
        let data = try JSONEncoder.iso.encode(tx)
        try PrivateStorage.writeAtomically(data, to: transactionURL, mode: 0o600)
    }

    private static func readTransaction() throws -> Transaction? {
        var st = stat()
        guard lstat(transactionURL.path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: "briglia.agentmail", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(transactionFileName) is not a regular file"])
        }
        let data = try Data(contentsOf: transactionURL)
        return try JSONDecoder.iso.decode(Transaction.self, from: data)
    }

    /// Validate every filename and hash in the metadata (plan §6.6 step 3):
    /// basenames only, versioned pattern, named files are regular when
    /// present. Returns the reason when invalid.
    static func validate(_ tx: Transaction) -> String? {
        guard ["staged", "committing", "committed", "rolled_back"].contains(tx.state) else { return "unknown state '\(tx.state)'" }
        guard validBasename(tx.newBinary) else { return "new_binary is not a plain versioned basename" }
        if let prev = tx.previousBinary, !validBasename(prev) { return "previous_binary is not a plain versioned basename" }
        guard tx.newSHA256.count == 64, tx.newWrapperSHA256.count == 64 else { return "hash fields malformed" }
        if let prev = tx.previousWrapper {
            guard prev.sha256.count == 64, let bytes = Data(base64Encoded: prev.bytesB64),
                  sha256Hex(bytes) == prev.sha256 else { return "previous_wrapper bytes do not match their hash" }
        }
        for name in [tx.newBinary, tx.previousBinary].compactMap({ $0 }) {
            let path = installDirectory.appendingPathComponent(name).path
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG { return "\(name) exists but is not a regular file (symlink?)" }
        }
        return nil
    }

    private static func atomicReplaceWrapper(bytes: Data, mode: mode_t) throws {
        try PrivateStorage.writeAtomically(bytes, to: wrapperURL, mode: mode)
    }

    private static func liveWrapperBytes() -> Data? {
        var st = stat()
        guard lstat(wrapperURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? Data(contentsOf: wrapperURL)
    }

    private static func crashIf(_ point: String) {
        if crashPoint == point { kill(getpid(), SIGKILL) }
    }

    private static func deleteIfUnreferenced(_ name: String, liveTarget: String?) {
        let path = installDirectory.appendingPathComponent(name).path
        if let liveTarget, liveTarget == path { return }
        unlink(path)
    }

    private static func removeStaging() {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(atPath: installDirectory.path)) ?? [] where entry.hasPrefix(stagingPrefix) {
            try? fm.removeItem(at: installDirectory.appendingPathComponent(entry))
        }
    }

    // MARK: Install

    /// Returns nil on success or a human-readable failure. `checkpoint`
    /// throws to abort (quick setup's authorization generation); a
    /// `CancellationError` is treated the same way.
    static func installAgentMailBinary(
        progress: (@Sendable (String) -> Void)? = nil,
        checkpoint: () throws -> Void = {},
        runner: ChildRunner = .plain
    ) async -> String? {
        do {
            return try await withInstallerLock {
                try await installLocked(progress: progress, checkpoint: checkpoint, runner: runner)
            }
        } catch is InstallerBusy {
            return "another AgentMail installation or repair is in progress — retry in a moment"
        } catch {
            return "install failed: \(error.localizedDescription)"
        }
    }

    private static func installLocked(
        progress: (@Sendable (String) -> Void)?,
        checkpoint: () throws -> Void,
        runner: ChildRunner
    ) async throws -> String? {
        // Settle any interrupted transaction first (repair is idempotent).
        if try readTransaction() != nil {
            let outcome = await repairLocked(runner: runner)
            if case .failedClosed(let why) = outcome { return why }
            if try readTransaction() != nil { return "an interrupted AgentMail transaction could not be settled — run `briglia agentmail repair`" }
        }
        try checkpoint()

        // 1. Download.
        let fixture: DownloadFixture
        if let downloadOverride {
            fixture = try await downloadOverride(progress)
        } else {
            fixture = try await downloadRelease(progress: progress)
        }
        try Task.checkCancellation()
        try checkpoint()
        guard let checksums = String(data: fixture.checksums, encoding: .utf8),
              let line = checksums.split(separator: "\n").first(where: { $0.contains(fixture.asset) }),
              let expected = line.split(separator: " ").first.map(String.init)?.lowercased(),
              expected.count == 64 else {
            return "checksum for \(fixture.asset) not found in checksums file"
        }
        guard sha256Hex(fixture.archive) == expected else {
            return "checksum mismatch — download corrupted or release changed mid-flight, retry"
        }

        // 2. Stage under the install directory (same filesystem).
        let fm = FileManager.default
        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let staging = installDirectory.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var stagingKept = false
        defer { if !stagingKept { try? fm.removeItem(at: staging) } }
        let archivePath = staging.appendingPathComponent(fixture.asset)
        try fixture.archive.write(to: archivePath)
        progress?("Extracting the agentmail CLI…")
        let untar = await runner.run(["/usr/bin/tar", "-xf", archivePath.path, "-C", staging.path], 60, "extract agentmail")
        guard untar.ok else { return "extraction failed: \(untar.detail ?? "tar failed")" }
        try checkpoint()
        let stagedBinary = staging.appendingPathComponent("agentmail")
        var st = stat()
        guard lstat(stagedBinary.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return "archive did not contain the agentmail binary"
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBinary.path)
        #if os(macOS)
        let xattr = await runner.run(["/usr/bin/xattr", "-d", "com.apple.quarantine", stagedBinary.path], 10, "unquarantine agentmail")
        if !xattr.ok, !((xattr.detail ?? "").contains("No such xattr") || (xattr.stdout ?? "").contains("No such xattr")) {
            // A missing attribute is success; anything else is a real failure.
            if let detail = xattr.detail, !detail.contains("exit 1") { return "xattr failed: \(detail)" }
        }
        try checkpoint()
        #endif
        let binaryData = try Data(contentsOf: stagedBinary)
        let binarySHA = sha256Hex(binaryData)
        let versioned = versionedName(version: fixture.version, sha256: binarySHA)
        let versionedPath = installDirectory.appendingPathComponent(versioned).path
        let wrapperText = wrapperScript(adaPath: brigliaPath(), realBinaryPath: versionedPath)
        let wrapperBytes = Data(wrapperText.utf8)
        let stagedWrapper = staging.appendingPathComponent("agentmail-wrapper")
        // The staged wrapper points at the versioned path; for the staged
        // smoke test the binary itself is run directly.
        try wrapperBytes.write(to: stagedWrapper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedWrapper.path)
        progress?("Checking the downloaded binary…")
        let stagedSmoke = await runner.run([stagedBinary.path, "--version"], 10, "agentmail --version (staged)")
        guard stagedSmoke.ok else { return "downloaded binary failed to run: \(stagedSmoke.detail ?? "unknown error")" }
        try checkpoint()

        // Existing versioned file?
        var binaryAlreadyPublished = false
        if lstat(versionedPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG, let existing = try? Data(contentsOf: URL(fileURLWithPath: versionedPath)),
                  sha256Hex(existing) == binarySHA else {
                return "a file named \(versioned) exists with unexpected content; remove it by hand if it is not yours"
            }
            binaryAlreadyPublished = true
        }

        // 3. Transaction metadata, then publish the binary.
        try checkpoint()
        let liveWrapper = liveWrapperBytes()
        let liveTarget = liveWrapper.flatMap(wrapperTarget)
        var previousBinary: String?
        if let liveTarget {
            let base = URL(fileURLWithPath: liveTarget).lastPathComponent
            if URL(fileURLWithPath: liveTarget).deletingLastPathComponent().path == installDirectory.path, validBasename(base) {
                previousBinary = base
            }
        } else if lstat(installDirectory.appendingPathComponent(legacyBinaryName).path, &st) == 0 {
            previousBinary = legacyBinaryName
        }
        var previous: PreviousWrapper?
        if let liveWrapper {
            var wst = stat()
            lstat(wrapperURL.path, &wst)
            previous = PreviousWrapper(bytesB64: liveWrapper.base64EncodedString(), sha256: sha256Hex(liveWrapper),
                                       mode: Int(wst.st_mode & 0o777))
        }
        var tx = Transaction(state: "staged", newBinary: versioned, newSHA256: binarySHA,
                             newWrapperSHA256: sha256Hex(wrapperBytes), previousWrapper: previous,
                             previousBinary: previousBinary, startedAt: Date())
        try writeTransaction(tx)
        crashIf("after-metadata")
        try checkpoint()
        if !binaryAlreadyPublished {
            guard rename(stagedBinary.path, versionedPath) == 0 else {
                let why = String(cString: strerror(errno))
                unlink(transactionURL.path)
                return "could not publish the binary: \(why)"
            }
            try fsyncDir()
        }
        crashIf("after-binary")
        stagingKept = false

        // 4. Commit (three states).
        try checkpoint()
        tx.state = "committing"
        try writeTransaction(tx)
        crashIf("after-committing")
        try atomicReplaceWrapper(bytes: wrapperBytes, mode: 0o755)
        crashIf("after-swap")
        tx.state = "committed"
        try writeTransaction(tx)
        crashIf("after-committed")

        // 5. Verify through the published wrapper, else roll back.
        progress?("Verifying the installation…")
        return await verifyOrRollback(tx, runner: runner)
    }

    /// Step 5 and the `committed` repair branch.
    private static func verifyOrRollback(_ tx: Transaction, runner: ChildRunner) async -> String? {
        let smoke = await runner.run([wrapperURL.path, "--version"], 10, "agentmail --version")
        if smoke.ok {
            let liveTarget = liveWrapperBytes().flatMap(wrapperTarget)
            if let prev = tx.previousBinary, prev != tx.newBinary {
                deleteIfUnreferenced(prev, liveTarget: liveTarget)
            }
            unlink(transactionURL.path)
            removeStaging()
            try? fsyncDir()
            return nil
        }
        let detail = smoke.detail ?? "unknown error"
        do {
            try rollbackLocked(tx)
        } catch {
            return "installed binary failed to run (\(detail)) and the rollback failed too: \(error.localizedDescription) — run `briglia agentmail repair`"
        }
        return "installed binary failed to run: \(detail) — the previous installation was restored"
    }

    /// One atomic wrapper operation, guarded by the wrapper inspection: the
    /// swap happens only if the live wrapper still hashes to the new one.
    private static func rollbackLocked(_ txIn: Transaction) throws {
        var tx = txIn
        let live = liveWrapperBytes()
        let liveHash = live.map(sha256Hex)
        if liveHash == tx.newWrapperSHA256 {
            if let prev = tx.previousWrapper, let bytes = Data(base64Encoded: prev.bytesB64) {
                try atomicReplaceWrapper(bytes: bytes, mode: mode_t(prev.mode))
            } else {
                unlink(wrapperURL.path)
                try fsyncDir()
            }
            crashIf("after-rollback-swap")
        }
        tx.state = "rolled_back"
        try writeTransaction(tx)
        let liveTarget = liveWrapperBytes().flatMap(wrapperTarget)
        deleteIfUnreferenced(tx.newBinary, liveTarget: liveTarget)
        unlink(transactionURL.path)
        removeStaging()
        try fsyncDir()
    }

    // MARK: Repair

    enum RepairOutcome: Equatable {
        case nothingToDo
        case settled(String)
        case failedClosed(String)
        case busy
    }

    /// `briglia agentmail repair` and quick setup's preflight: takes the
    /// lock, validates the metadata, then settles the transaction by
    /// inspecting the LIVE wrapper (never the state alone). Idempotent.
    static func repairTransaction(runner: ChildRunner = .plain) async -> RepairOutcome {
        do {
            return try await withInstallerLock { await repairLocked(runner: runner) }
        } catch is InstallerBusy {
            return .busy
        } catch {
            return .failedClosed("repair could not start: \(error.localizedDescription)")
        }
    }

    private static func repairLocked(runner: ChildRunner) async -> RepairOutcome {
        let tx: Transaction
        do {
            guard let read = try readTransaction() else {
                removeStaging()
                return .nothingToDo
            }
            tx = read
        } catch {
            return .failedClosed("\(transactionFileName) cannot be read (\(error.localizedDescription)); inspect \(installDirectory.path), then delete the file to abandon the transaction")
        }
        if let why = validate(tx) {
            return .failedClosed("\(transactionFileName) is invalid (\(why)); nothing was changed — inspect \(installDirectory.path)/agentmail and \(transactionFileName), then delete the metadata to abandon the transaction")
        }
        let live = liveWrapperBytes()
        let liveHash = live.map(sha256Hex)
        let liveTarget = live.flatMap(wrapperTarget)
        let newBinaryPath = installDirectory.appendingPathComponent(tx.newBinary).path

        func cleanPreCommit() -> RepairOutcome {
            deleteIfUnreferenced(tx.newBinary, liveTarget: liveTarget)
            unlink(transactionURL.path)
            removeStaging()
            try? fsyncDir()
            return .settled("the wrapper was never replaced; the previous installation is live and the new binary was removed")
        }
        func classifyCommitting() -> String {
            // previous wrapper live (or absent on a fresh install) → pre-commit
            if let prev = tx.previousWrapper {
                if liveHash == prev.sha256 { return "pre" }
            } else if live == nil {
                return "pre"
            }
            if liveHash == tx.newWrapperSHA256, liveTarget == newBinaryPath { return "post" }
            return "neither"
        }

        switch tx.state {
        case "staged":
            return cleanPreCommit()
        case "rolled_back":
            return cleanPreCommit()
        case "committing", "committed":
            let cls = tx.state == "committed" ? "post" : classifyCommitting()
            switch cls {
            case "pre":
                return cleanPreCommit()
            case "post":
                if tx.state == "committing" {
                    var updated = tx
                    updated.state = "committed"
                    do { try writeTransaction(updated) } catch { return .failedClosed("could not update the metadata: \(error.localizedDescription)") }
                }
                var verified = tx
                verified.state = "committed"
                let result = await verifyOrRollback(verified, runner: runner)
                if let result { return .settled("the new pair was live but failed verification: \(result)") }
                return .settled("the new pair was live; verification passed and the transaction was completed")
            default:
                return .failedClosed("the AgentMail wrapper does not match this transaction's previous or new wrapper; inspect \(wrapperURL.path) and \(transactionURL.path), then delete \(transactionFileName) to abandon the transaction or restore the wrapper by hand")
            }
        default:
            return .failedClosed("unknown transaction state '\(tx.state)'")
        }
    }

    /// Doctor's read-only view: nil when there is nothing to report.
    static func transactionReport() -> String? {
        if installerLockBusy() { return "AgentMail installation in progress (another process holds the installer lock)" }
        var st = stat()
        guard lstat(transactionURL.path, &st) == 0 else { return nil }
        do {
            guard let tx = try readTransaction() else { return nil }
            if let why = validate(tx) {
                return "AgentMail install transaction metadata is invalid (\(why)); run `briglia agentmail repair` for instructions"
            }
            return "AgentMail install transaction interrupted at state \(tx.state); run `briglia agentmail repair`"
        } catch {
            return "AgentMail install transaction metadata cannot be read (\(error.localizedDescription)); run `briglia agentmail repair`"
        }
    }

    // MARK: Download

    private static func downloadRelease(progress: (@Sendable (String) -> Void)?) async throws -> DownloadFixture {
        guard let apiURL = URL(string: "https://api.github.com/repos/agentmail-to/agentmail-cli/releases/latest") else {
            throw NSError(domain: "briglia.agentmail", code: 10, userInfo: [NSLocalizedDescriptionKey: "internal error: malformed release-lookup URL"])
        }
        var lookup = URLRequest(url: apiURL)
        lookup.timeoutInterval = 30
        lookup.setValue("briglia-cli", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: lookup)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "briglia.agentmail", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "release lookup failed (HTTP \(code)) — GitHub may be rate-limiting; retry in a few minutes"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw NSError(domain: "briglia.agentmail", code: 12, userInfo: [NSLocalizedDescriptionKey: "release lookup returned no tag"])
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        #if os(Linux)
        #if arch(arm64)
        let platformArch = "linux_arm64"
        #else
        let platformArch = "linux_amd64"
        #endif
        let ext = "tar.gz"
        #else
        #if arch(arm64)
        let platformArch = "macos_arm64"
        #else
        let platformArch = "macos_amd64"
        #endif
        let ext = "zip"
        #endif
        let asset = "agentmail_\(version)_\(platformArch).\(ext)"
        let base = "https://github.com/agentmail-to/agentmail-cli/releases/download/v\(version)/"
        guard let assetURL = URL(string: base + asset),
              let checksumsURL = URL(string: base + "agentmail_\(version)_checksums.txt") else {
            throw NSError(domain: "briglia.agentmail", code: 13, userInfo: [NSLocalizedDescriptionKey: "internal error: malformed release URL"])
        }
        let archive = try await GoogleWorkspaceService.downloadReportingProgress(
            from: assetURL, label: "Downloading the agentmail CLI", progress: progress)
        try Task.checkCancellation()
        let (checksumData, checksumResp) = try await URLSession.shared.data(from: checksumsURL)
        if let code = (checksumResp as? HTTPURLResponse)?.statusCode, code != 200 {
            throw NSError(domain: "briglia.agentmail", code: 14, userInfo: [NSLocalizedDescriptionKey: "checksum download failed (HTTP \(code))"])
        }
        return (version, asset, archive, checksumData)
    }
}
