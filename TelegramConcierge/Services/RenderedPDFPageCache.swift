import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One rasterized-and-recompressed PDF page ready for inline attachment.
struct RenderedPDFPage {
    let data: Data
    let mimeType: String
}

/// Process-wide memo of rendered PDF pages, keyed by content hash of the
/// source PDF bytes. Request assembly re-inlines every historical PDF
/// attachment on every turn; without this cache each turn re-runs the
/// rasterizer (a pdftoppm subprocess round-trip per document on Linux) and
/// the JPEG recompression for identical bytes. In-memory only — entries are
/// cheap to rebuild, so nothing persists across restarts.
final class RenderedPDFPageCache {
    static let shared = RenderedPDFPageCache()

    private let lock = NSLock()
    private var entries: [String: [RenderedPDFPage]] = [:]
    private var lruOrder: [String] = []   // least-recently-used first
    private var totalBytes = 0
    private let maxTotalBytes: Int

    init(maxTotalBytes: Int = 64 * 1024 * 1024) {
        self.maxTotalBytes = maxTotalBytes
    }

    static func key(for pdfData: Data) -> String {
        SHA256.hash(data: pdfData).map { String(format: "%02x", $0) }.joined()
    }

    private static func cost(of pages: [RenderedPDFPage]) -> Int {
        pages.reduce(0) { $0 + $1.data.count }
    }

    func pages(forKey key: String) -> [RenderedPDFPage]? {
        lock.lock(); defer { lock.unlock() }
        guard let pages = entries[key] else { return nil }
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
            lruOrder.append(key)
        }
        return pages
    }

    func store(_ pages: [RenderedPDFPage], forKey key: String) {
        guard !pages.isEmpty else { return }
        let cost = Self.cost(of: pages)
        // An entry bigger than the whole budget would evict everything else
        // and then be evicted itself by the next store; don't cache it.
        guard cost <= maxTotalBytes else { return }
        lock.lock(); defer { lock.unlock() }
        if let existing = entries.removeValue(forKey: key) {
            totalBytes -= Self.cost(of: existing)
            lruOrder.removeAll { $0 == key }
        }
        entries[key] = pages
        lruOrder.append(key)
        totalBytes += cost
        while totalBytes > maxTotalBytes, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                totalBytes -= Self.cost(of: evicted)
            }
        }
    }

    /// Drops every cached page. Called by the /deleteuserdata wipe so rendered
    /// pages of deleted documents don't outlive the wipe in process memory.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        lruOrder = []
        totalBytes = 0
    }

    var currentTotalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return totalBytes
    }
}
