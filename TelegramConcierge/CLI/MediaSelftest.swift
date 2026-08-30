import ArgumentParser
import Foundation

/// Hidden diagnostic: runs the cross-platform media layer (AdaPDF +
/// PlatformImage) against embedded fixtures. On macOS this exercises
/// PDFKit/ImageIO; on Linux it exercises the poppler/ImageMagick subprocess
/// pipeline — CI runs it on both, and it doubles as a user-facing diagnostic
/// when PDFs or images misbehave.
struct MediaSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "media-selftest",
        abstract: "Verify the PDF/image pipeline (poppler/ImageMagick on Linux).",
        shouldDisplay: false
    )

    // A 2-page 200×100pt PDF ("Ada page one" / "Ada page two") and a 64×40
    // red PNG, generated once and embedded so the check has no file deps.
    private static let fixturePDFBase64 = "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUiA0IDAgUl0gL0NvdW50IDIgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMTAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA3IDAgUiA+PiA+PiAvQ29udGVudHMgNSAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCAyMDAgMTAwXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA3IDAgUiA+PiA+PiAvQ29udGVudHMgNiAwIFIgPj4KZW5kb2JqCjUgMCBvYmoKPDwgL0xlbmd0aCA0MiA+PgpzdHJlYW0KQlQgL0YxIDEyIFRmIDIwIDUwIFRkIChBZGEgcGFnZSBvbmUpIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNiAwIG9iago8PCAvTGVuZ3RoIDQyID4+CnN0cmVhbQpCVCAvRjEgMTIgVGYgMjAgNTAgVGQgKEFkYSBwYWdlIHR3bykgVGogRVQKZW5kc3RyZWFtCmVuZG9iago3IDAgb2JqCjw8IC9UeXBlIC9Gb250IC9TdWJ0eXBlIC9UeXBlMSAvQmFzZUZvbnQgL0hlbHZldGljYSA+PgplbmRvYmoKeHJlZgowIDgKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDEyMSAwMDAwMCBuIAowMDAwMDAwMjQ3IDAwMDAwIG4gCjAwMDAwMDAzNzMgMDAwMDAgbiAKMDAwMDAwMDQ2NSAwMDAwMCBuIAowMDAwMDAwNTU3IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgOCAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYKNjI3CiUlRU9GCg=="
    private static let fixturePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAoCAIAAADBrGu+AAAAT0lEQVR4nO3PAQkAAAyEwO9feoshgnABdLep8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyPEFDcjxBQ3I8QUNyD0aJPaIiU1OTAAAAABJRU5ErkJggg=="

    func run() async throws {
        var failures = 0
        func check(_ label: String, _ ok: Bool, detail: String? = nil) {
            print("  \(ok ? "✔" : "✖") \(label)\(ok ? "" : detail.map { " — \($0)" } ?? "")")
            if !ok { failures += 1 }
        }

        guard let pdfData = Data(base64Encoded: Self.fixturePDFBase64),
              let pngData = Data(base64Encoded: Self.fixturePNGBase64) else {
            throw ValidationError("embedded fixtures failed to decode")
        }

        print("PDF pipeline")
        if let doc = AdaPDF(data: pdfData) {
            check("open + page count (2)", doc.pageCount == 2, detail: "got \(doc.pageCount)")
            let text = doc.pageText(at: 0) ?? ""
            check("text extraction", text.contains("Ada page one"), detail: "got '\(text.prefix(40))'")
            if let slice = doc.sliceData(pages: 2...2), let sliced = AdaPDF(data: slice) {
                check("page slicing (1 page)", sliced.pageCount == 1
                      && (sliced.pageText(at: 0) ?? "").contains("two"),
                      detail: "pages=\(sliced.pageCount)")
            } else {
                check("page slicing (1 page)", false, detail: "sliceData returned nil")
            }
            let rasters = doc.rasterizePagesToPNG(scale: 2.0)
            let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            check("rasterization (2 PNG pages)",
                  rasters.count == 2 && rasters.allSatisfy { $0.count > 100 && [UInt8]($0.prefix(4)) == pngMagic },
                  detail: "got \(rasters.count) pages")
        } else {
            check("open + page count (2)", false, detail: "AdaPDF(data:) returned nil — is poppler-utils installed?")
            check("text extraction", false); check("page slicing (1 page)", false); check("rasterization (2 PNG pages)", false)
        }

        print("Image pipeline")
        let dims = PlatformImage.dimensions(data: pngData)
        check("dimensions (64×40)", dims?.width == 64 && dims?.height == 40,
              detail: dims.map { "got \($0.width)×\($0.height)" } ?? "nil — is ImageMagick installed?")
        let jpegMagic: [UInt8] = [0xFF, 0xD8]
        let resized = PlatformImage.resizeToJPEG(data: pngData, targetSize: CGSize(width: 32, height: 20), quality: 0.8)
        check("resize + JPEG encode", (resized?.count ?? 0) > 50 && [UInt8]((resized ?? Data()).prefix(2)) == jpegMagic,
              detail: "got \(resized?.count ?? 0) bytes")
        if let resized, let newDims = PlatformImage.dimensions(data: resized) {
            check("resized dimensions (32×20)", newDims.width == 32 && newDims.height == 20,
                  detail: "got \(newDims.width)×\(newDims.height)")
        } else {
            check("resized dimensions (32×20)", false, detail: "no resized data")
        }

        print("Rendered-page recompression")
        // Over-budget page: synthesize a 2000×1250 image (upscaled fixture) and
        // verify it comes back as a JPEG capped at imageMaxLongSide.
        if let big = PlatformImage.resizeToJPEG(data: pngData, targetSize: CGSize(width: 2000, height: 1250), quality: 0.9) {
            let compressed = FilesystemTools.recompressedRenderedPage(big)
            let outDims = PlatformImage.dimensions(data: compressed.data)
            let longSide = max(outDims?.width ?? 0, outDims?.height ?? 0)
            check("over-budget page → downscaled JPEG",
                  compressed.mimeType == "image/jpeg"
                  && longSide > 0 && longSide <= FilesystemTools.imageMaxLongSide,
                  detail: "mime=\(compressed.mimeType) longSide=\(longSide)")
        } else {
            check("over-budget page → downscaled JPEG", false, detail: "could not synthesize test image")
        }
        // In-budget rasterized page: recompression never grows the payload and
        // preserves dimensions on whichever branch (JPEG re-encode or PNG keep).
        if let doc = AdaPDF(data: pdfData), let raster = doc.rasterizePagesToPNG(scale: 2.0).first {
            let inDims = PlatformImage.dimensions(data: raster)
            let compressed = FilesystemTools.recompressedRenderedPage(raster)
            let outDims = PlatformImage.dimensions(data: compressed.data)
            check("in-budget page: no growth, dims preserved",
                  !compressed.data.isEmpty && compressed.data.count <= raster.count
                  && ["image/png", "image/jpeg"].contains(compressed.mimeType)
                  && outDims?.width == inDims?.width && outDims?.height == inDims?.height,
                  detail: "mime=\(compressed.mimeType) \(raster.count)→\(compressed.data.count) bytes")
        } else {
            check("in-budget page: no growth, dims preserved", false, detail: "rasterization unavailable")
        }
        // Codex repro: sparse pages (mostly-white fixture) PNG-compress below
        // their JPEG re-encode, so an over-budget rasterized PNG must come
        // back unchanged rather than grown — the no-growth guarantee wins
        // over the dimension cap.
        if let doc = AdaPDF(data: pdfData), let bigRaster = doc.rasterizePagesToPNG(scale: 16.0).first {
            let inDims = PlatformImage.dimensions(data: bigRaster)
            let compressed = FilesystemTools.recompressedRenderedPage(bigRaster)
            check("over-budget rasterized PNG: never grows",
                  max(inDims?.width ?? 0, inDims?.height ?? 0) > FilesystemTools.imageMaxLongSide
                  && !compressed.data.isEmpty
                  && compressed.data.count <= bigRaster.count,
                  detail: "dims=\(inDims.map { "\($0.width)×\($0.height)" } ?? "?") \(bigRaster.count)→\(compressed.data.count) bytes mime=\(compressed.mimeType)")
        } else {
            check("over-budget rasterized PNG: never grows", false, detail: "rasterization unavailable")
        }

        print("Rendered-page cache")
        let pageA = RenderedPDFPage(data: Data(repeating: 0xA, count: 40), mimeType: "image/jpeg")
        let pageB = RenderedPDFPage(data: Data(repeating: 0xB, count: 40), mimeType: "image/jpeg")
        let pageC = RenderedPDFPage(data: Data(repeating: 0xC, count: 40), mimeType: "image/jpeg")
        let keyA = RenderedPDFPageCache.key(for: Data("doc-a".utf8))
        let keyB = RenderedPDFPageCache.key(for: Data("doc-b".utf8))
        let keyC = RenderedPDFPageCache.key(for: Data("doc-c".utf8))
        check("content-hash keys: stable and distinct",
              keyA == RenderedPDFPageCache.key(for: Data("doc-a".utf8)) && keyA != keyB)

        let cache = RenderedPDFPageCache(maxTotalBytes: 100)
        cache.store([pageA], forKey: keyA)
        check("store + retrieve roundtrip",
              cache.pages(forKey: keyA)?.first?.data == pageA.data
              && cache.pages(forKey: keyB) == nil)

        // LRU: touch A, then store B and C (40+40+40 > 100) — the untouched
        // oldest after A's refresh is evicted first, so A survives.
        cache.store([pageB], forKey: keyB)
        _ = cache.pages(forKey: keyA)          // refresh A
        cache.store([pageC], forKey: keyC)     // exceeds budget → evict LRU (B)
        check("LRU eviction respects access order",
              cache.pages(forKey: keyB) == nil
              && cache.pages(forKey: keyA) != nil
              && cache.pages(forKey: keyC) != nil,
              detail: "bytes=\(cache.currentTotalBytes)")

        let huge = RenderedPDFPage(data: Data(repeating: 0xF, count: 101), mimeType: "image/jpeg")
        cache.store([huge], forKey: RenderedPDFPageCache.key(for: Data("huge".utf8)))
        check("over-budget entry not cached",
              cache.pages(forKey: RenderedPDFPageCache.key(for: Data("huge".utf8))) == nil
              && cache.pages(forKey: keyA) != nil)

        cache.removeAll()
        check("removeAll clears entries and byte count",
              cache.pages(forKey: keyA) == nil && cache.currentTotalBytes == 0)

        if failures > 0 {
            print("\n\(failures) media check(s) failed.")
            throw ExitCode(1)
        }
        print("\nMedia pipeline healthy.")
    }
}
