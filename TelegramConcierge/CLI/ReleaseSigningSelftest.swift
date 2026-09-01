import ArgumentParser
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

/// Battery for the signed release channel (docs/RELEASE_SIGNING_PLAN.md §11):
/// RFC 8032 vectors, envelope/domain rules, strict manifest validation,
/// sequence/anti-rollback decisions, the trust store, bounded streaming
/// downloads against a local HTTP server, and OpenSSL ↔ Swift interop
/// through the real keygen + signing scripts.
struct ReleaseSigningSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__release-signing-selftest",
        abstract: "Run the release-signing verification battery.",
        shouldDisplay: false
    )

    func run() throws {
        var passed = 0
        var failed = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                passed += 1
                print("  ✔ \(label)")
            } else {
                failed += 1
                print("  ✖ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ada-relsign-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // ------------------------------------------------------------------
        print("— RFC 8032 §7.1 vectors —")
        let vectors: [(seed: String, pub: String, msg: String, sig: String)] = [
            // TEST 1 (empty message)
            ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
             "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
             "",
             "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155" +
             "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
            // TEST 2 (one byte 0x72)
            ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
             "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
             "72",
             "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
            // TEST 3 (two bytes af82)
            ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
             "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
             "af82",
             "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"),
        ]
        for (index, vector) in vectors.enumerated() {
            let pub = Self.hexData(vector.pub)!
            let msg = Self.hexData(vector.msg) ?? Data()
            let sig = Self.hexData(vector.sig)!
            check("vector \(index + 1) verifies",
                  ReleaseSigning.ed25519Verify(publicKey: pub, signature: sig, message: msg))
            var badSig = sig
            badSig[0] ^= 0x01
            check("vector \(index + 1) rejects flipped signature bit",
                  !ReleaseSigning.ed25519Verify(publicKey: pub, signature: badSig, message: msg))
            var badMsg = msg
            if badMsg.isEmpty { badMsg = Data([0x00]) } else { badMsg[0] ^= 0x01 }
            check("vector \(index + 1) rejects altered message",
                  !ReleaseSigning.ed25519Verify(publicKey: pub, signature: sig, message: badMsg))
        }
        check("wrong signature length rejected",
              !ReleaseSigning.ed25519Verify(
                publicKey: Self.hexData(vectors[0].pub)!,
                signature: Data(repeating: 0, count: 63), message: Data()))
        check("wrong key length rejected",
              !ReleaseSigning.ed25519Verify(
                publicKey: Data(repeating: 0, count: 31),
                signature: Data(repeating: 0, count: 64), message: Data()))

        // ------------------------------------------------------------------
        print("— envelope verification —")
        let signer = TestSigner()
        let policy = signer.policy
        let goodManifest = Self.manifestJSON()
        let goodEnvelope = signer.envelope(manifest: goodManifest)

        func verify(_ envelope: Data, now: Date = Date()) -> Result<ReleaseSigning.Manifest, Error> {
            Result { try ReleaseSigning.verifyEnvelope(envelope, policy: policy, now: now) }
        }
        func expectError(_ label: String, _ envelope: Data, now: Date = Date(),
                         _ match: (ReleaseVerifyError) -> Bool) {
            switch verify(envelope, now: now) {
            case .success: check(label, false, "verification unexpectedly succeeded")
            case .failure(let error):
                guard let typed = error as? ReleaseVerifyError else {
                    check(label, false, "unexpected error type: \(error)")
                    return
                }
                check(label, match(typed), "got \(typed)")
            }
        }

        switch verify(goodEnvelope) {
        case .success(let manifest):
            check("valid envelope verifies", true)
            check("manifest fields authenticated", manifest.version == "0.1.59"
                  && manifest.sequence == 59
                  && manifest.platforms["macos-arm64"]?.size == 1000)
        case .failure(let error):
            check("valid envelope verifies", false, "\(error)")
            check("manifest fields authenticated", false)
        }

        do {
            let empty = ReleasePolicy(keys: [], channel: "briglia-cli",
                                      artifactURLPrefix: policy.artifactURLPrefix)
            _ = try ReleaseSigning.verifyEnvelope(goodEnvelope, policy: empty)
            check("empty pinned key set fails closed", false, "unexpectedly succeeded")
        } catch let error as ReleaseVerifyError {
            if case .noPinnedKeys = error { check("empty pinned key set fails closed", true) }
            else { check("empty pinned key set fails closed", false, "\(error)") }
        } catch { check("empty pinned key set fails closed", false, "\(error)") }

        expectError("altered payload rejected",
                    signer.envelope(manifest: goodManifest, tamperPayload: true)) {
            if case .badSignature = $0 { return true }; return false
        }
        expectError("altered signature rejected",
                    signer.envelope(manifest: goodManifest, tamperSignature: true)) {
            if case .badSignature = $0 { return true }; return false
        }
        expectError("unknown keyId rejected",
                    signer.envelope(manifest: goodManifest, keyIdOverride: "briglia-cli-release-v1-ffffffffffffffff")) {
            if case .unknownKey = $0 { return true }; return false
        }
        expectError("known keyId with mismatched domain rejected",
                    signer.envelope(manifest: goodManifest, signDomainKeyId: "other-key")) {
            if case .badSignature = $0 { return true }; return false
        }
        expectError("wrong format rejected",
                    signer.envelope(manifest: goodManifest, formatOverride: "ada-release-envelope-v2")) {
            if case .unsupportedFormat = $0 { return true }; return false
        }
        expectError("cross-channel envelope rejected",
                    signer.envelope(manifest: goodManifest, channelOverride: "briglia-ut")) {
            if case .wrongChannel = $0 { return true }; return false
        }
        expectError("briglia-cli envelope signed under briglia-ut domain rejected",
                    signer.envelope(manifest: goodManifest, signDomainChannel: "briglia-ut")) {
            if case .badSignature = $0 { return true }; return false
        }
        // Rename plan §3.1: a genuine PRE-RENAME envelope (retired channel
        // `ada-cli`, same key material, matching keyId shape) is structurally
        // a foreign domain — an installed Briglia never accepts it, whatever
        // the channel serves during the transition window.
        expectError("legacy ada-cli envelope (same key, legacy channel + keyId) rejected",
                    signer.envelope(manifest: goodManifest,
                                    keyIdOverride: "ada-cli-release-v1-" + String(signer.keyId.suffix(16)),
                                    channelOverride: "ada-cli",
                                    signDomainChannel: "ada-cli",
                                    signDomainKeyId: "ada-cli-release-v1-" + String(signer.keyId.suffix(16)))) {
            if case .wrongChannel = $0 { return true }; return false
        }
        expectError("noncanonical base64 payload rejected",
                    signer.envelope(manifest: goodManifest, noncanonicalPayload: true)) {
            if case .malformedEnvelope = $0 { return true }; return false
        }
        expectError("whitespace in base64 rejected",
                    signer.envelope(manifest: goodManifest, whitespacePayload: true)) {
            if case .malformedEnvelope = $0 { return true }; return false
        }
        expectError("63-byte signature rejected",
                    signer.envelope(manifest: goodManifest, truncateSignature: true)) {
            if case .malformedEnvelope = $0 { return true }; return false
        }
        expectError("not-JSON envelope rejected", Data("not json at all".utf8)) {
            if case .malformedEnvelope = $0 { return true }; return false
        }
        expectError("oversized raw envelope rejected",
                    Data(repeating: 0x20, count: ReleaseSigning.maxEnvelopeBytes + 1)) {
            if case .envelopeTooLarge = $0 { return true }; return false
        }
        let hugePayload = Self.manifestJSON(padding: ReleaseSigning.maxPayloadBytes)
        expectError("oversized decoded payload rejected",
                    signer.envelope(manifest: hugePayload)) {
            if case .payloadTooLarge = $0 { return true }; return false
        }

        // ------------------------------------------------------------------
        print("— manifest validation (authenticated payload) —")
        func expectManifestError(_ label: String, _ manifest: Data, now: Date = Date(),
                                 _ match: (ReleaseVerifyError) -> Bool) {
            do {
                _ = try ReleaseSigning.verifyEnvelope(
                    signer.envelope(manifest: manifest), policy: policy, now: now)
                check(label, false, "unexpectedly accepted")
            } catch let error as ReleaseVerifyError {
                check(label, match(error), "got \(error)")
            } catch {
                check(label, false, "unexpected error \(error)")
            }
        }
        expectManifestError("schema 2 rejected", Self.manifestJSON(schema: 2)) {
            if case .malformedManifest = $0 { return true }; return false
        }
        expectManifestError("wrong manifest channel rejected", Self.manifestJSON(channel: "briglia-ut")) {
            if case .wrongChannel = $0 { return true }; return false
        }
        expectManifestError("non-positive sequence rejected", Self.manifestJSON(sequence: 0)) {
            if case .malformedManifest = $0 { return true }; return false
        }
        expectManifestError("non-SemVer version rejected", Self.manifestJSON(version: "0.1.59-rc1")) {
            if case .malformedManifest = $0 { return true }; return false
        }
        expectManifestError("expired metadata rejected",
                            Self.manifestJSON(expires: "2020-01-01T00:00:00Z")) {
            if case .expired = $0 { return true }; return false
        }
        expectManifestError("future published beyond skew rejected",
                            Self.manifestJSON(published: "2199-01-01T00:00:00Z")) {
            if case .notYetValid = $0 { return true }; return false
        }
        do {
            // published slightly in the future (within the 24h allowance) is OK
            let soon = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
            _ = try ReleaseSigning.verifyEnvelope(
                signer.envelope(manifest: Self.manifestJSON(published: soon)), policy: policy)
            check("published within clock-skew allowance accepted", true)
        } catch {
            check("published within clock-skew allowance accepted", false, "\(error)")
        }
        expectManifestError("garbled timestamp rejected",
                            Self.manifestJSON(published: "yesterday")) {
            if case .malformedManifest = $0 { return true }; return false
        }
        expectManifestError("empty platforms rejected", Self.manifestJSON(platformsJSON: "{}")) {
            if case .malformedManifest = $0 { return true }; return false
        }
        expectManifestError("http URL rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(url: "http://github.com/permaevidence/briglia-cli/releases/download/v0.1.59/a.tar.gz"))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("wrong host rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(url: "https://evil.example.com/permaevidence/briglia-cli/releases/download/v0.1.59/a.tar.gz"))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("wrong repo path rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(url: "https://github.com/evil/briglia-cli/releases/download/v0.1.59/a.tar.gz"))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("version-mismatched asset path rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(url: "https://github.com/permaevidence/briglia-cli/releases/download/v0.0.1/a.tar.gz"))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("path traversal in asset name rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(url: "https://github.com/permaevidence/briglia-cli/releases/download/v0.1.59/../evil.tar.gz"))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("uppercase sha256 rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(sha256: String(repeating: "A", count: 64)))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("short sha256 rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(sha256: String(repeating: "a", count: 63)))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("zero size rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(size: 0))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }
        expectManifestError("absurd size rejected", Self.manifestJSON(
            platformsJSON: Self.platformJSON(size: ReleaseSigning.maxArtifactBytes + 1))) {
            if case .badPlatformEntry = $0 { return true }; return false
        }

        // ------------------------------------------------------------------
        print("— sequence / anti-rollback decisions —")
        func manifest(_ sequence: Int, _ version: String) -> ReleaseSigning.Manifest {
            try! ReleaseSigning.verifyEnvelope(
                signer.envelope(manifest: Self.manifestJSON(sequence: sequence, version: version)),
                policy: policy)
        }
        func decision(_ sequence: Int, _ version: String, installed: String = "0.1.58",
                      own: Int = 58, persisted: Int? = nil,
                      platform: String = "macos-arm64") -> UpgradeService.CheckResult {
            UpgradeService.decide(manifest: manifest(sequence, version),
                                  installedVersion: installed, ownSequence: own,
                                  persistedSequence: persisted, platform: platform)
        }
        if case .rollbackRefused(let live, let floor) = decision(57, "0.1.57") {
            check("sequence below embedded floor refused", live == 57 && floor == 58)
        } else { check("sequence below embedded floor refused", false) }
        if case .rollbackRefused(_, let floor) = decision(59, "0.1.59", persisted: 60) {
            check("sequence below persisted floor refused", floor == 60)
        } else { check("sequence below persisted floor refused", false) }
        if case .upToDate = decision(58, "0.1.58") {
            check("own sequence + own version = up to date", true)
        } else { check("own sequence + own version = up to date", false) }
        if case .failed = decision(58, "0.1.99") {
            check("own sequence + different newer version refused", true)
        } else { check("own sequence + different newer version refused", false) }
        if case .failed = decision(59, "0.1.58") {
            check("newer sequence repeating installed version refused", true)
        } else { check("newer sequence repeating installed version refused", false) }
        if case .manifestOlder = decision(59, "0.1.2") {
            check("newer sequence with older version = not a downgrade path", true)
        } else { check("newer sequence with older version = not a downgrade path", false) }
        if case .available(let update) = decision(59, "0.1.59") {
            check("newer sequence + newer version = available", update.version == "0.1.59"
                  && update.size == 1000)
        } else { check("newer sequence + newer version = available", false) }
        if case .noBuildForPlatform = decision(59, "0.1.59", platform: "linux-riscv") {
            check("missing platform reported", true)
        } else { check("missing platform reported", false) }

        // ------------------------------------------------------------------
        print("— trust store —")
        let trustFile = work.appendingPathComponent("release_trust.json")
        setenv("BRIGLIA_RELEASE_TRUST_FILE", trustFile.path, 1)
        defer { unsetenv("BRIGLIA_RELEASE_TRUST_FILE") }
        // "prod" = whatever repository THIS build is stamped for (the staging
        // pipeline stamps its own), "staging" = any other pinned location.
        let prod = ReleasePolicy.production.trustDomain
        let staging = ReleasePolicy(
            keys: ReleaseKeys.active, channel: "briglia-cli",
            artifactURLPrefix: "https://github.com/permaevidence/briglia-cli-other-channel/releases/download/v{version}/"
        ).trustDomain
        check("trust domain = channel + pinned artifact location",
              prod == "briglia-cli|https://github.com/\(adaCLIReleaseRepository)/releases/download/v{version}/"
              && prod != staging, prod)
        check("absent file loads as absent, not corrupt",
              ReleaseTrustStore.load(domain: prod).sequence == nil
              && !ReleaseTrustStore.load(domain: prod).corrupt)
        try ReleaseTrustStore.store(61, domain: prod)
        check("stored sequence round-trips", ReleaseTrustStore.load(domain: prod).sequence == 61)
        check("other domain is unaffected (staging cannot block production)",
              ReleaseTrustStore.load(domain: staging).sequence == nil)
        let notLowered = try ReleaseTrustStore.store(59, domain: prod)
        check("store never lowers the floor (max(stored, new))",
              notLowered == 61 && ReleaseTrustStore.load(domain: prod).sequence == 61)
        try ReleaseTrustStore.store(70, domain: staging)
        check("domains are independent floors",
              ReleaseTrustStore.load(domain: prod).sequence == 61
              && ReleaseTrustStore.load(domain: staging).sequence == 70)
        let onDisk = String(decoding: try Data(contentsOf: trustFile), as: UTF8.self)
        check("on-disk state is schema 2 keyed by domain",
              onDisk.contains("\"schema\":2") && onDisk.contains(prod) && onDisk.contains(staging), onDisk)
        check("lock file is a sibling, not inside the replaced state file",
              fm.fileExists(atPath: trustFile.path + ".lock"))
        try Data("garbage".utf8).write(to: trustFile)
        let corrupt = ReleaseTrustStore.load(domain: prod)
        check("corrupt file reported as corrupt", corrupt.sequence == nil && corrupt.corrupt)
        try Data("{\"highestVerifiedSequence\":60}".utf8).write(to: trustFile)
        let legacy = ReleaseTrustStore.load(domain: prod)
        check("legacy v1 global sequence is not attributed to any domain (reported, ignored)",
              legacy.sequence == nil && legacy.corrupt)
        try Data("{\"schema\":2,\"domains\":{\"\(prod)\":0}}".utf8).write(to: trustFile)
        check("non-positive persisted sequence treated as corrupt",
              ReleaseTrustStore.load(domain: prod).corrupt)
        try ReleaseTrustStore.store(62, domain: prod)
        check("store recovers over corrupt file", ReleaseTrustStore.load(domain: prod).sequence == 62)
        // (the corrupt rewrite legitimately dropped the staging entry — a
        // corrupt file carries no trustworthy floor; re-seed it for the race)
        try ReleaseTrustStore.store(70, domain: staging)

        // Concurrency: many writers racing on one domain must converge on
        // the maximum, and no writer may ever observe its own value lost.
        do {
            let racers = 8, rounds = 40
            final class Tally: @unchecked Sendable {
                let lock = NSLock()
                var maxStored = 0
                var regressions = 0
                var errors = 0
            }
            let tally = Tally()
            let group = DispatchGroup()
            for racer in 0..<racers {
                group.enter()
                DispatchQueue.global().async {
                    var generator = SystemRandomNumberGenerator()
                    for _ in 0..<rounds {
                        let value = Int.random(in: 100...5000, using: &generator) + racer
                        do {
                            let merged = try ReleaseTrustStore.store(value, domain: "race")
                            tally.lock.lock()
                            tally.maxStored = max(tally.maxStored, value)
                            if merged < value { tally.regressions += 1 }
                            tally.lock.unlock()
                        } catch {
                            tally.lock.lock(); tally.errors += 1; tally.lock.unlock()
                        }
                    }
                    group.leave()
                }
            }
            group.wait()
            let final = ReleaseTrustStore.load(domain: "race")
            check("\(racers) concurrent writers converge on the maximum",
                  tally.errors == 0 && tally.regressions == 0 && final.sequence == tally.maxStored
                  && !final.corrupt,
                  "errors \(tally.errors) regressions \(tally.regressions) final \(final.sequence ?? -1) max \(tally.maxStored)")
            check("other domains survive the race intact",
                  ReleaseTrustStore.load(domain: prod).sequence == 62
                  && ReleaseTrustStore.load(domain: staging).sequence == 70)
        }

        // Real flock contention: while this process holds LOCK_EX on the
        // sibling lock (a distinct open file description, exactly like
        // another ada process would), a store must block, then complete.
        do {
            let lockFD = open(trustFile.path + ".lock", O_RDWR | O_CREAT, 0o600)
            check("selftest can open the lock file", lockFD >= 0)
            check("selftest takes LOCK_EX", flock(lockFD, LOCK_EX) == 0)
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            final class Box: @unchecked Sendable { var result: Int? }
            let box = Box()
            DispatchQueue.global().async {
                started.signal()
                box.result = try? ReleaseTrustStore.store(99, domain: prod)
                finished.signal()
            }
            started.wait()
            let blocked = finished.wait(timeout: .now() + 0.4) == .timedOut
            check("store blocks while another holder owns the lock", blocked)
            _ = flock(lockFD, LOCK_UN)
            close(lockFD)
            let completed = finished.wait(timeout: .now() + 10) == .success
            check("store completes once the lock is released", completed && box.result == 99)
            check("blocked store merged correctly", ReleaseTrustStore.load(domain: prod).sequence == 99)
        }

        // ------------------------------------------------------------------
        print("— bounded HTTP (local server) —")
        try Self.runBoundedHTTPChecks(work: work, check: check)

        // ------------------------------------------------------------------
        print("— OpenSSL ↔ Swift interop (real keygen + signing scripts) —")
        try Self.runOpenSSLInterop(work: work, check: check)

        print("")
        if failed == 0 {
            print("ALL \(passed) RELEASE-SIGNING CHECKS PASSED")
        } else {
            print("\(failed) FAILED, \(passed) passed")
            throw ExitCode(1)
        }
    }

    // MARK: - helpers

    static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// In-process Ed25519 signer with a fresh key, mirroring the production
    /// envelope layout, with tampering hooks for the negative tests.
    final class TestSigner {
        let privateKey = Curve25519.Signing.PrivateKey()
        var publicKey: Data { privateKey.publicKey.rawRepresentation }
        var keyId: String {
            let fp = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
            return "briglia-cli-release-v1-\(fp.prefix(16))"
        }
        var policy: ReleasePolicy {
            ReleasePolicy(
                keys: [ReleaseKey(keyId: keyId,
                                  publicKeyHex: publicKey.map { String(format: "%02x", $0) }.joined())!],
                channel: "briglia-cli",
                artifactURLPrefix: "https://github.com/permaevidence/briglia-cli/releases/download/v{version}/")
        }

        func envelope(
            manifest: Data,
            tamperPayload: Bool = false, tamperSignature: Bool = false,
            keyIdOverride: String? = nil, formatOverride: String? = nil,
            channelOverride: String? = nil,
            signDomainChannel: String? = nil, signDomainKeyId: String? = nil,
            noncanonicalPayload: Bool = false, whitespacePayload: Bool = false,
            truncateSignature: Bool = false
        ) -> Data {
            let channel = channelOverride ?? "briglia-cli"
            let usedKeyId = keyIdOverride ?? keyId
            let message = ReleaseSigning.domainInput(
                channel: signDomainChannel ?? channel,
                keyId: signDomainKeyId ?? usedKeyId,
                payload: manifest)
            var signature = try! privateKey.signature(for: message)
            if tamperSignature { signature[0] ^= 0x01 }
            if truncateSignature { signature = signature.dropFirst() }
            var payload = manifest
            if tamperPayload { payload.append(Data(" ".utf8)) }
            var payloadB64 = payload.base64EncodedString()
            if noncanonicalPayload {
                // Flip unused trailing bits in the final base64 character:
                // decodes to the same bytes, re-encodes differently.
                if payloadB64.hasSuffix("=") {
                    let index = payloadB64.index(payloadB64.endIndex, offsetBy: payloadB64.hasSuffix("==") ? -3 : -2)
                    payloadB64.replaceSubrange(index...index, with: "9")
                } else {
                    payloadB64 += "AA=="
                }
            }
            if whitespacePayload { payloadB64 += "\n" }
            let envelope: [String: String] = [
                "format": formatOverride ?? ReleaseSigning.formatName,
                "channel": channel,
                "keyId": usedKeyId,
                "payload": payloadB64,
                "signature": signature.base64EncodedString(),
            ]
            return try! JSONSerialization.data(withJSONObject: envelope)
        }
    }

    static func platformJSON(
        url: String = "https://github.com/permaevidence/briglia-cli/releases/download/v{version}/briglia-macos-arm64.tar.gz",
        sha256: String = String(repeating: "ab", count: 32),
        size: Int64 = 1000
    ) -> String {
        "{\"macos-arm64\":{\"url\":\"\(url)\",\"sha256\":\"\(sha256)\",\"size\":\(size)}}"
    }

    static func manifestJSON(
        schema: Int = 1, channel: String = "briglia-cli", sequence: Int = 59,
        version: String = "0.1.59",
        published: String = "2026-08-01T00:00:00Z",
        expires: String = "2199-01-01T00:00:00Z",
        platformsJSON: String? = nil, padding: Int = 0
    ) -> Data {
        let platforms = (platformsJSON ?? platformJSON())
            .replacingOccurrences(of: "{version}", with: version)
        var json = """
        {"schema":\(schema),"channel":"\(channel)","sequence":\(sequence),\
        "version":"\(version)","published":"\(published)","expires":"\(expires)",\
        "platforms":\(platforms)
        """
        if padding > 0 {
            json += ",\"pad\":\"\(String(repeating: "x", count: padding))\""
        }
        json += "}"
        return Data(json.utf8)
    }

    // MARK: - bounded HTTP against a local python server

    static func runBoundedHTTPChecks(work: URL, check: (String, Bool, String) -> Void) throws {
        let serverScript = work.appendingPathComponent("server.py")
        try Data(boundedHTTPServerPy.utf8).write(to: serverScript)
        let artifact = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        try artifact.write(to: work.appendingPathComponent("artifact.bin"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", serverScript.path, work.path]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        // corelibs Process.waitUntilExit can hang on Linux when the child
        // (a threaded HTTP server with lingering keep-alive connections)
        // trips the socketpair exit-detection pitfall — kill hard and do
        // NOT block on reaping; this selftest process exits moments later
        // and init reaps the zombie.
        defer { kill(process.processIdentifier, SIGKILL) }
        guard let portLine = out.fileHandleForReading.availableData.split(separator: 0x0a).first,
              let port = Int(String(decoding: portLine, as: UTF8.self)) else {
            check("local HTTP server started", false, "no port line")
            return
        }
        check("local HTTP server started", true, "")
        let base = "http://127.0.0.1:\(port)"

        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: String] = [:]
            func set(_ key: String, _ value: String) {
                lock.lock(); storage[key] = value; lock.unlock()
            }
            func get(_ key: String) -> String? {
                lock.lock(); defer { lock.unlock() }; return storage[key]
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        let results = ResultBox()
        Task.detached {
            func record(_ key: String, _ value: String) { results.set(key, value) }
            // small fetch within cap
            do {
                let data = try await BoundedHTTP.fetchData(
                    url: URL(string: "\(base)/small")!, maxBytes: 128 * 1024)
                record("small", data.count == 1024 ? "ok" : "wrong size \(data.count)")
            } catch { record("small", "error \(error.localizedDescription)") }
            // oversized response aborts mid-stream
            do {
                _ = try await BoundedHTTP.fetchData(
                    url: URL(string: "\(base)/big")!, maxBytes: 128 * 1024)
                record("big", "unexpectedly succeeded")
            } catch { record("big", error.localizedDescription.contains("limit") ? "ok" : "wrong error: \(error.localizedDescription)") }
            // artifact: exact size + streaming hash
            do {
                let dest = work.appendingPathComponent("dl-exact.bin")
                let digest = try await BoundedHTTP.downloadFile(
                    url: URL(string: "\(base)/artifact")!, to: dest,
                    expectedBytes: Int64(artifact.count))
                let expected = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
                record("exact", digest == expected ? "ok" : "hash mismatch")
            } catch { record("exact", "error \(error.localizedDescription)") }
            // truncated artifact (server closes early) fails
            do {
                let dest = work.appendingPathComponent("dl-trunc.bin")
                _ = try await BoundedHTTP.downloadFile(
                    url: URL(string: "\(base)/truncated")!, to: dest,
                    expectedBytes: Int64(artifact.count))
                record("truncated", "unexpectedly succeeded")
            } catch { record("truncated", "ok") }
            // artifact longer than authenticated size aborts
            do {
                let dest = work.appendingPathComponent("dl-over.bin")
                _ = try await BoundedHTTP.downloadFile(
                    url: URL(string: "\(base)/artifact")!, to: dest,
                    expectedBytes: 1000)
                record("oversize", "unexpectedly succeeded")
            } catch { record("oversize", error.localizedDescription.contains("limit") ? "ok" : "wrong error: \(error.localizedDescription)") }
            // 404 fails with status error
            do {
                _ = try await BoundedHTTP.fetchData(
                    url: URL(string: "\(base)/missing")!, maxBytes: 1024)
                record("status", "unexpectedly succeeded")
            } catch { record("status", error.localizedDescription.contains("HTTP 404") ? "ok" : "wrong error: \(error.localizedDescription)") }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 120) == .success else {
            check("bounded HTTP checks completed", false, "timed out")
            return
        }
        check("bounded fetch within cap", results.get("small") == "ok", results.get("small") ?? "missing")
        check("oversized response aborted while streaming", results.get("big") == "ok", results.get("big") ?? "missing")
        check("artifact exact size + streaming hash", results.get("exact") == "ok", results.get("exact") ?? "missing")
        check("truncated artifact refused", results.get("truncated") == "ok", results.get("truncated") ?? "missing")
        check("artifact over authenticated size aborted", results.get("oversize") == "ok", results.get("oversize") ?? "missing")
        check("HTTP error status surfaced", results.get("status") == "ok", results.get("status") ?? "missing")
    }

    static let boundedHTTPServerPy = """
    import http.server, os, socketserver, sys
    root = sys.argv[1]
    artifact = open(os.path.join(root, "artifact.bin"), "rb").read()
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            if self.path == "/small":
                body = b"x" * 1024
                self.send_response(200); self.send_header("Content-Length", str(len(body)))
                self.end_headers(); self.wfile.write(body)
            elif self.path == "/big":
                body = b"y" * (300 * 1024)
                self.send_response(200); self.send_header("Content-Length", str(len(body)))
                self.end_headers(); self.wfile.write(body)
            elif self.path == "/artifact":
                self.send_response(200); self.send_header("Content-Length", str(len(artifact)))
                self.end_headers(); self.wfile.write(artifact)
            elif self.path == "/truncated":
                self.send_response(200); self.send_header("Content-Length", str(len(artifact)))
                self.end_headers(); self.wfile.write(artifact[: len(artifact) // 2])
                self.wfile.flush(); self.connection.close()
            else:
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    class S(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
    with S(("127.0.0.1", 0), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
    """

    // MARK: - OpenSSL interop through the real scripts

    static func runOpenSSLInterop(work: URL, check: (String, Bool, String) -> Void) throws {
        let fm = FileManager.default
        let repoRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
        let keygen = repoRoot.appendingPathComponent("scripts/release-keygen.sh")
        let signer = repoRoot.appendingPathComponent(".github/scripts/sign-envelope.sh")
        #if os(Linux)
        let scriptsRequired = true
        #else
        let scriptsRequired = ProcessInfo.processInfo.environment["CI"] != nil
        #endif
        guard fm.fileExists(atPath: keygen.path), fm.fileExists(atPath: signer.path) else {
            if scriptsRequired {
                check("interop scripts present", false, "run from the repository root")
            } else {
                print("  – SKIP: signing scripts not found (run from the repo root to include interop)")
            }
            return
        }

        func run(_ path: String, _ args: [String], env: [String: String] = [:]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [path] + args
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env { environment[key] = value }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: output, as: UTF8.self))
        }

        let keyDir = work.appendingPathComponent("keys")
        let (keygenStatus, keygenOut) = try run(keygen.path, ["briglia-cli", keyDir.path])
        if keygenStatus != 0 {
            #if os(Linux)
            check("release-keygen.sh generates a key", false, keygenOut)
            #else
            if keygenOut.contains("no Ed25519-capable openssl") {
                print("  – SKIP: no Ed25519-capable openssl on this machine")
            } else {
                check("release-keygen.sh generates a key", false, keygenOut)
            }
            #endif
            return
        }
        check("release-keygen.sh generates a key", true, "")

        guard let record = try fm.contentsOfDirectory(at: keyDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "json" }),
            let recordData = try? Data(contentsOf: record),
            let info = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any],
            let keyId = info["keyId"] as? String,
            let publicKeyHex = info["publicKeyHex"] as? String,
            let pinned = ReleaseKey(keyId: keyId, publicKeyHex: publicKeyHex)
        else {
            check("key record parses and pins", false, "missing or malformed key record")
            return
        }
        check("key record parses and pins", true, "")
        check("keyId embeds the fingerprint prefix",
              keyId.hasPrefix("briglia-cli-release-v1-") && keyId.count == "briglia-cli-release-v1-".count + 16, keyId)
        let fingerprint = SHA256.hash(data: pinned.publicKey).map { String(format: "%02x", $0) }.joined()
        check("fingerprint matches raw public key", keyId.hasSuffix(String(fingerprint.prefix(16))), "")

        let manifestFile = work.appendingPathComponent("manifest.json")
        try manifestJSON().write(to: manifestFile)
        let envelopeFile = work.appendingPathComponent("manifest.sig.json")
        let privPEM = keyDir.appendingPathComponent("\(keyId).priv.pem")
        let pubPEM = keyDir.appendingPathComponent("\(keyId).pub.pem")
        let (signStatus, signOut) = try run(
            signer.path, [privPEM.path, "briglia-cli", manifestFile.path, envelopeFile.path],
            env: ["EXPECTED_PUBKEY_PEM": pubPEM.path])
        check("sign-envelope.sh signs (known-vector + wrong-key guards pass)",
              signStatus == 0 && signOut.contains("known-vector check passed"), signOut)
        guard signStatus == 0 else { return }

        let interopPolicy = ReleasePolicy(
            keys: [pinned], channel: "briglia-cli",
            artifactURLPrefix: "https://github.com/permaevidence/briglia-cli/releases/download/v{version}/")
        do {
            let envelopeData = try Data(contentsOf: envelopeFile)
            let manifest = try ReleaseSigning.verifyEnvelope(envelopeData, policy: interopPolicy)
            check("Swift verifier accepts the OpenSSL-signed envelope",
                  manifest.version == "0.1.59" && manifest.sequence == 59, "")
        } catch {
            check("Swift verifier accepts the OpenSSL-signed envelope", false, "\(error)")
        }

        // wrong-key guard: signing with a key that doesn't match the expected
        // public key must refuse.
        let otherDir = work.appendingPathComponent("keys2")
        _ = try run(keygen.path, ["briglia-cli", otherDir.path])
        if let otherPriv = try fm.contentsOfDirectory(at: otherDir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasSuffix(".priv.pem") }) {
            let (mismatchStatus, mismatchOut) = try run(
                signer.path, [otherPriv.path, "briglia-cli", manifestFile.path,
                              work.appendingPathComponent("bad.sig.json").path],
                env: ["EXPECTED_PUBKEY_PEM": pubPEM.path])
            check("sign-envelope.sh refuses a mismatched private key",
                  mismatchStatus != 0 && mismatchOut.contains("DIFFERENT public key"), mismatchOut)
        } else {
            check("sign-envelope.sh refuses a mismatched private key", false, "second keygen failed")
        }
    }
}
