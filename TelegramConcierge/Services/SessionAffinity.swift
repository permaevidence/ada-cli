import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security)
import Security
#endif

/// Which conversation a model request belongs to, for provider session
/// affinity (plan `SESSION_AFFINITY_PLAN.md` §3.1). Every model-request
/// builder takes one explicitly; there is no default and no task-local
/// fallback, so a new request site that forgets it fails to compile.
enum AffinityLane: Equatable {
    /// The main conversation (turns and the pruning summaries built on it).
    case main
    /// The archive service's own byte-stable prefix (chunk summaries,
    /// meta-summaries, user-context extraction/restructure).
    case archive
    /// One subagent session, by its registry session ID (new or resumed,
    /// including every compaction/retry request the run makes).
    case subagent(String)
    /// One web-agent run, one OCR/vision/description call, one
    /// UserContextStructurer operation. Never a subagent.
    case ephemeral(UUID)
    /// One outer setup/doctor probe operation (shared by its fallback
    /// candidates).
    case probe(UUID)

    var laneId: String {
        switch self {
        case .main: return "main"  // completed with the conversation ID at derivation time
        case .archive: return "archive"
        case .subagent(let id): return "subagent:\(id)"
        case .ephemeral(let id): return "ephemeral:\(id.uuidString.lowercased())"
        case .probe(let id): return "probe:\(id.uuidString.lowercased())"
        }
    }
}

/// Per-install session-affinity state and the one decorator every model
/// request goes through (plan §4–§7).
///
/// Wire value: `hex(HMAC-SHA256(installSalt, "briglia-affinity-v1" ‖
/// len32(SHA256(apiKey)) ‖ SHA256(apiKey) ‖ len32(laneId) ‖ laneId))[0..<32]`.
/// Opaque, stable per (key, lane, install), unlinkable across keys.
enum SessionAffinity {
    struct State: Codable, Equatable {
        let version: Int
        let installSalt: String        // base64, 32 bytes
        let mainConversationId: String // UUID string

        var saltBytes: Data? {
            guard let d = Data(base64Encoded: installSalt), d.count == 32 else { return nil }
            return d
        }
        var isValid: Bool {
            version == SessionAffinity.currentVersion && saltBytes != nil
                && UUID(uuidString: mainConversationId) != nil
        }
    }

    struct AffinityError: Error, CustomStringConvertible {
        let description: String
    }

    /// Which side of the atomic rename a write failed on (plan §5/§8):
    /// before → the old file is byte-identical; after → the complete new
    /// state is in place but its directory entry was not proven durable.
    enum WritePhase { case beforeRename, afterRename }
    struct WriteFailure: Error, CustomStringConvertible {
        let phase: WritePhase
        let description: String
    }

    static let currentVersion = 1
    static let fileName = "affinity.json"
    static let lockName = "affinity.lock"
    static let corruptPrefix = "affinity.json.corrupt-"
    static let opencodeHeader = "x-opencode-session"
    static let openrouterHeader = "x-session-id"

    static var fileURL: URL { StoragePaths.dataRoot.appendingPathComponent(fileName) }
    static var lockURL: URL { StoragePaths.dataRoot.appendingPathComponent(lockName) }

    /// Client identification for every model request (plan §6): the
    /// product and version, never the user.
    static var userAgent: String { "Briglia/\(adaCLIVersion) (\(PlatformOS.userAgentToken))" }

    // MARK: - Test seams (used in-process by `__affinity-selftest` only)

    struct TestHooks {
        /// Thrown between the temp-file fsync and the rename.
        var beforeRename: (() throws -> Void)? = nil
        /// Thrown in place of the post-rename directory fsync.
        var afterRename: (() throws -> Void)? = nil
        /// Makes the quarantine rename fail.
        var quarantineRenameFails = false
        /// Makes the CSPRNG fail.
        var randomFails = false
        /// Extra log sink for the selftest (warnings are also printed).
        var warningSink: ((String) -> Void)? = nil
        /// Runs inside `affinity.lock` after the state was read and before it
        /// is published to the cache (the race window Codex round 1 named).
        var afterReadBeforePublish: (() -> Void)? = nil
    }
    nonisolated(unsafe) static var testHooks = TestHooks()

    // MARK: - Host rules (plan §6, v7)

    /// Development builds may point the OpenCode / OpenRouter host rule at a
    /// local capture server; release builds ignore the variables (same gate
    /// as `DevProbeOverride`).
    private static func devBase(_ env: String) -> URL? {
        guard adaCLIVersion.hasSuffix("-dev"),
              let raw = ProcessInfo.processInfo.environment[env], !raw.isEmpty,
              let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }
    private static func matchesDev(_ url: URL, _ dev: URL?) -> Bool {
        guard let dev else { return false }
        return url.scheme?.lowercased() == dev.scheme?.lowercased()
            && url.host?.lowercased() == dev.host?.lowercased()
            && url.port == dev.port
    }
    private static func hostMatches(_ url: URL, apex: String) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        return host == apex || host.hasSuffix("." + apex)
    }

    /// `https://opencode.ai/...` or a label-suffix subdomain; nothing else.
    static func isOpenCodeURL(_ url: URL) -> Bool {
        matchesDev(url, devBase("BRIGLIA_DEV_AFFINITY_OPENCODE_BASE")) || hostMatches(url, apex: "opencode.ai")
    }
    /// `https://openrouter.ai/...` or a label-suffix subdomain.
    static func isOpenRouterURL(_ url: URL) -> Bool {
        matchesDev(url, devBase("BRIGLIA_DEV_AFFINITY_OPENROUTER_BASE")) || hostMatches(url, apex: "openrouter.ai")
    }
    /// The parsed-host replacement for `baseURL.contains("opencode.ai")`.
    static func isOpenCodeBaseURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        return isOpenCodeURL(url)
    }

    // MARK: - Derivation (plan §4)

    static func wireId(state: State, apiKey: String, lane: AffinityLane) -> String {
        let fingerprint = Data(SHA256.hash(data: Data(apiKey.utf8)))
        let laneId: String
        switch lane {
        case .main: laneId = "main:\(state.mainConversationId.lowercased())"
        default: laneId = lane.laneId
        }
        var message = Data("briglia-affinity-v1".utf8)
        func append(_ part: Data) {
            var len = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &len) { message.append(contentsOf: $0) }
            message.append(part)
        }
        append(fingerprint)
        append(Data(laneId.utf8))
        let key = SymmetricKey(data: state.saltBytes ?? Data(count: 32))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return String(Data(mac).map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    // MARK: - Decorator (plan §7)

    /// Headers to merge into a model request for `url`: `User-Agent`
    /// always; the OpenCode session header (required — a failed load
    /// throws); the OpenRouter session + attribution headers (best effort —
    /// a failed load omits the session header with one warning).
    static func headers(url: URL, apiKey: String, lane: AffinityLane) throws -> [String: String] {
        var headers = ["User-Agent": userAgent]
        if isOpenCodeURL(url) {
            let state = try loadState()
            headers[opencodeHeader] = wireId(state: state, apiKey: apiKey, lane: lane)
        } else if isOpenRouterURL(url) {
            headers["HTTP-Referer"] = "https://briglia.dev"
            headers["X-Title"] = "Briglia"
            do {
                let state = try loadState()
                headers[openrouterHeader] = wireId(state: state, apiKey: apiKey, lane: lane)
            } catch {
                // Best effort: one warning per process, not one per request.
                cacheLock.lock()
                let first = !openRouterWarned
                openRouterWarned = true
                cacheLock.unlock()
                if first { warn("OpenRouter request sent without \(openrouterHeader) (further occurrences not logged): \(error)") }
            }
        }
        return headers
    }

    static func decorate(_ request: inout URLRequest, apiKey: String, lane: AffinityLane) throws {
        guard let url = request.url else { return }
        for (name, value) in try headers(url: url, apiKey: apiKey, lane: lane) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    // MARK: - State cache

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: State?
    nonisolated(unsafe) private static var quarantinedThisProcess = false
    nonisolated(unsafe) private static var openRouterWarned = false

    /// Forget the cached state (after every writer, including failed ones).
    static func resetCache() {
        cacheLock.lock(); cached = nil; cacheLock.unlock()
    }

    /// Selftest only: also forget the once-per-process quarantine mark.
    static func resetProcessStateForTests() {
        cacheLock.lock(); cached = nil; quarantinedThisProcess = false; openRouterWarned = false; cacheLock.unlock()
    }

    private static func warn(_ text: String) {
        print("[SessionAffinity] warning: \(text)")
        testHooks.warningSink?(text)
    }

    // MARK: - Load / create / quarantine (plan §5)

    enum FileRead {
        case absent
        case decoded(State)
        case undecodable(Data)
        case ioError(String)
    }

    static func readFile() -> FileRead {
        let path = fileURL.path
        var st = stat()
        if lstat(path, &st) != 0 {
            let code = errno
            return code == ENOENT ? .absent : .ioError("lstat \(path): \(String(cString: strerror(code)))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .ioError("\(path) is not a regular file (mode \(String(st.st_mode & S_IFMT, radix: 8)))")
        }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            return .ioError("open \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return .ioError("read \(path): \(String(cString: strerror(errno)))")
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > 65536 { return .undecodable(data) }
        }
        if let state = try? JSONDecoder().decode(State.self, from: data), state.isValid {
            return .decoded(state)
        }
        return .undecodable(data)
    }

    /// The state, loading it from disk on first use (creating it under the
    /// lock if absent, quarantining an undecodable file once per process).
    /// Only a successfully decoded state is cached, and it is published to
    /// the cache while `affinity.lock` is still held: every in-process
    /// writer invalidates the cache under that same lock, so a load that
    /// read the old file can never be published after a writer's reset
    /// (Codex round 1).
    static func loadState() throws -> State {
        cacheLock.lock()
        if let cached { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        return try withLock {
            let state = try loadStateLocked()
            testHooks.afterReadBeforePublish?()
            cacheLock.lock(); cached = state; cacheLock.unlock()
            return state
        }
    }

    private static func loadStateLocked() throws -> State {
        switch readFile() {
        case .decoded(let state):
            return state
        case .ioError(let why):
            throw AffinityError(description: "cannot read \(fileURL.path): \(why) — repair the file or its permissions and retry")
        case .absent:
            let fresh = try mintState(mainConversationId: UUID().uuidString.lowercased())
            try writeState(fresh)
            return fresh
        case .undecodable(let bytes):
            cacheLock.lock()
            let already = quarantinedThisProcess
            cacheLock.unlock()
            if already {
                throw AffinityError(description: "\(fileURL.path) is undecodable again after a quarantine in this process (\(bytes.count) bytes) — inspect the file; run `briglia doctor`")
            }
            let corrupt = try quarantineLocked()
            cacheLock.lock(); quarantinedThisProcess = true; cacheLock.unlock()
            let fresh = try mintState(mainConversationId: UUID().uuidString.lowercased())
            try writeState(fresh)
            warn("\(fileURL.lastPathComponent) was undecodable; moved to \(corrupt.lastPathComponent) and regenerated (new salt and conversation ID)")
            return fresh
        }
    }

    private static func quarantineLocked() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var candidate = fileURL.deletingLastPathComponent()
            .appendingPathComponent(corruptPrefix + formatter.string(from: Date()))
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = fileURL.deletingLastPathComponent()
                .appendingPathComponent(corruptPrefix + formatter.string(from: Date()) + "-\(suffix)")
            suffix += 1
        }
        if testHooks.quarantineRenameFails {
            throw AffinityError(description: "could not quarantine \(fileURL.path) → \(candidate.lastPathComponent): injected failure")
        }
        guard rename(fileURL.path, candidate.path) == 0 else {
            throw AffinityError(description: "could not quarantine \(fileURL.path) → \(candidate.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        try PrivateStorage.fsyncDirectory(fileURL.deletingLastPathComponent().path)
        return candidate
    }

    private static func mintState(mainConversationId: String) throws -> State {
        guard let salt = randomBytes(count: 32) else {
            throw AffinityError(description: "system randomness unavailable; cannot create \(fileURL.lastPathComponent)")
        }
        return State(version: currentVersion, installSalt: salt.base64EncodedString(),
                     mainConversationId: mainConversationId)
    }

    private static func randomBytes(count: Int) -> Data? {
        if testHooks.randomFails { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        #if os(Linux)
        // Glibc does not export getrandom(2); /dev/urandom is the same
        // CSPRNG pool. Any failure aborts — never a weaker fallback.
        let fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var filled = 0
        while filled < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + filled, $0.count - filled) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return nil }
            filled += n
        }
        #else
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        #endif
        return Data(bytes)
    }

    // MARK: - Lock and durable write (plan §5)

    /// Cross-process serialisation of every create/update/delete: a
    /// sidecar `flock` opened without following symlinks.
    static func withLock<T>(_ body: () throws -> T) throws -> T {
        try PrivateStorage.ensureDirectory(StoragePaths.dataRoot)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw AffinityError(description: "cannot open \(lockURL.path) for locking: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw AffinityError(description: "cannot lock \(lockURL.path): \(String(cString: strerror(errno)))")
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Owner-only sibling temp file → fsync → rename onto `affinity.json` →
    /// fsync the directory. The final path is only ever the target of a
    /// rename, so power loss cannot leave a truncated file. Throws
    /// `WriteFailure` with the phase the caller must report.
    static func writeState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(state) + Data("\n".utf8)
        let dir = fileURL.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(fileName).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw WriteFailure(phase: .beforeRename, description: "could not create \(tmp.path): \(String(cString: strerror(errno)))")
        }
        var failure: String?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count, let base = raw.baseAddress {
                let n = write(fd, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = "write failed: \(String(cString: strerror(errno)))"
                    return
                }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = "fsync failed: \(String(cString: strerror(errno)))" }
        close(fd)
        if let failure {
            unlink(tmp.path)
            throw WriteFailure(phase: .beforeRename, description: "could not write \(fileURL.path): \(failure)")
        }
        if let hook = testHooks.beforeRename {
            do { try hook() } catch {
                unlink(tmp.path)
                throw WriteFailure(phase: .beforeRename, description: "could not write \(fileURL.path): \(error)")
            }
        }
        guard rename(tmp.path, fileURL.path) == 0 else {
            let why = String(cString: strerror(errno))
            unlink(tmp.path)
            throw WriteFailure(phase: .beforeRename, description: "could not move \(tmp.lastPathComponent) into place at \(fileURL.path): \(why)")
        }
        do {
            if let hook = testHooks.afterRename { try hook() } else { try PrivateStorage.fsyncDirectory(dir.path) }
        } catch {
            throw WriteFailure(phase: .afterRename, description: "\(fileURL.path) is in place but its directory entry is not proven durable: \(error)")
        }
    }

    // MARK: - Writers (plan §3.2, §3.3, §8, §9)

    /// `/rotateaffinity`: new install salt, same conversation ID. The cache
    /// is invalidated whether or not the write succeeds.
    static func rotateSalt() throws {
        try withLock {
            defer { resetCache() }   // under the file lock: ordered with every loader's publish
            let current = try loadStateLocked()
            guard let salt = randomBytes(count: 32) else {
                throw AffinityError(description: "system randomness unavailable; nothing changed")
            }
            try writeState(State(version: currentVersion, installSalt: salt.base64EncodedString(),
                                 mainConversationId: current.mainConversationId))
        }
    }

    /// Mind import: new main conversation ID, same salt. Returns the new ID.
    /// The cache is invalidated whether or not the write succeeds.
    @discardableResult
    static func replaceMainConversationId() throws -> String {
        return try withLock {
            defer { resetCache() }   // under the file lock: ordered with every loader's publish
            let current = try loadStateLocked()
            let next = UUID().uuidString.lowercased()
            try writeState(State(version: currentVersion, installSalt: current.installSalt,
                                 mainConversationId: next))
            return next
        }
    }

    /// `/deleteuserdata`: remove the file and every quarantined sibling under
    /// the lock, fsync the directory. Returns human-readable failures.
    static func deleteForUserDataWipe() -> [String] {
        var failures: [String] = []
        do {
            try withLock {
                defer { resetCache() }   // under the file lock, like every writer
                let dir = fileURL.deletingLastPathComponent()
                var targets = [fileURL.path]
                switch corruptFilesChecked() {
                case .success(let names):
                    targets += names.map { dir.appendingPathComponent($0).path }
                case .failure(let error):
                    failures.append("could not enumerate \(dir.path) for quarantined affinity files (they may remain): \(error)")
                }
                for path in targets where unlink(path) != 0 && errno != ENOENT {
                    failures.append("could not delete \(path): \(String(cString: strerror(errno)))")
                }
                do { try PrivateStorage.fsyncDirectory(dir.path) } catch {
                    failures.append("affinity directory fsync: \(error)")
                }
            }
        } catch {
            failures.append("affinity lock: \(error)")
        }
        return failures
    }

    /// Quarantined copies currently beside the file; an enumeration failure
    /// is a result, never an empty list (wipe and doctor report it).
    static func corruptFilesChecked() -> Result<[String], Error> {
        let dir = fileURL.deletingLastPathComponent()
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return .success(names.filter { $0.hasPrefix(corruptPrefix) }.sorted())
        } catch {
            return .failure(error)
        }
    }

    /// Convenience for callers that only need the list (selftests).
    static func corruptFiles() -> [String] {
        (try? corruptFilesChecked().get()) ?? []
    }

    // MARK: - Doctor (plan §10)

    struct DoctorFinding {
        let text: String
        let problem: Bool
        let hint: String?
    }

    static func doctorFindings(activeBaseURL: String) -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        switch readFile() {
        case .decoded:
            findings.append(DoctorFinding(text: "session affinity state present and valid (\(fileName))", problem: false, hint: nil))
        case .absent:
            findings.append(DoctorFinding(text: "session affinity state not created yet (\(fileName)); it is minted on the first model request", problem: false, hint: nil))
        case .undecodable(let bytes):
            findings.append(DoctorFinding(text: "session affinity state undecodable (\(fileName), \(bytes.count) bytes)", problem: true,
                                          hint: "it will be quarantined and regenerated on the next OpenCode request; delete it to force that now"))
        case .ioError(let why):
            findings.append(DoctorFinding(text: "session affinity state unreadable: \(why)", problem: true,
                                          hint: "OpenCode requests fail until \(fileURL.path) is a readable regular file"))
        }
        let receives: String
        if isOpenCodeBaseURL(activeBaseURL) { receives = "OpenCode (\(opencodeHeader), required)" }
        else if let url = URL(string: activeBaseURL), isOpenRouterURL(url) { receives = "OpenRouter (\(openrouterHeader), optional)" }
        else { receives = "none (custom or local endpoint)" }
        findings.append(DoctorFinding(text: "active provider session header: \(receives)", problem: false, hint: nil))
        switch corruptFilesChecked() {
        case .success(let corrupt):
            if !corrupt.isEmpty {
                findings.append(DoctorFinding(text: "\(corrupt.count) quarantined affinity file(s): \(corrupt.joined(separator: ", "))", problem: false,
                                              hint: "kept for inspection; removed by /deleteuserdata"))
            }
        case .failure(let error):
            findings.append(DoctorFinding(text: "cannot enumerate \(fileURL.deletingLastPathComponent().path) for quarantined affinity files: \(error)", problem: true,
                                          hint: "check the data root's permissions"))
        }
        return findings
    }
}
