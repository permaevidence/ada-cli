import Foundation

// MARK: - Document Metadata

struct DocumentMetadata {
    let fileName: String
    let fileSize: Int
    let mimeType: String?
    let pageCount: Int?  // For PDFs
    let textPreview: String?  // First portion of extracted text
}

// MARK: - Document Service

actor DocumentService {
    static let shared = DocumentService()
    
    /// Maximum characters to extract for LLM context (prevents token explosion)
    private let maxTextLength = 10000
    
    // MARK: - Text Extraction
    
    /// Extract text content from a document file
    /// Returns nil if text extraction is not supported for the file type
    func extractText(from url: URL) -> String? {
        let fileExtension = url.pathExtension.lowercased()
        
        switch fileExtension {
        case "pdf":
            return extractTextFromPDF(url)
        case "txt", "md", "json", "csv", "xml", "html", "css", "js", "swift", "py", "java", "c", "cpp", "h", "m", "mm":
            return extractTextFromPlainFile(url)
        default:
            let mimeType = FilesystemTools.mimeType(forPath: url.path)
            return isTextLikeMimeType(mimeType) ? extractTextFromPlainFile(url) : nil
        }
    }
    
    /// Extract text from a PDF file using PDFKit
    private func extractTextFromPDF(_ url: URL) -> String? {
        guard let document = AdaPDF(url: url) else {
            print("[DocumentService] Failed to open PDF: \(url.lastPathComponent)")
            return nil
        }
        
        var fullText = ""
        let pageCount = document.pageCount
        
        for i in 0..<pageCount {
            if let pageText = document.pageText(at: i) {
                fullText += pageText
                fullText += "\n\n"  // Page separator
            }
            
            // Stop early if we've extracted enough text
            if fullText.count >= maxTextLength {
                break
            }
        }
        
        // Truncate to max length
        if fullText.count > maxTextLength {
            fullText = String(fullText.prefix(maxTextLength)) + "\n[... document truncated ...]"
        }
        
        return fullText.isEmpty ? nil : fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Extract text from plain text files
    private func extractTextFromPlainFile(_ url: URL) -> String? {
        do {
            var text = try String(contentsOf: url, encoding: .utf8)
            
            // Truncate to max length
            if text.count > maxTextLength {
                text = String(text.prefix(maxTextLength)) + "\n[... file truncated ...]"
            }
            
            return text.isEmpty ? nil : text
        } catch {
            print("[DocumentService] Failed to read text file: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Metadata
    
    /// Get metadata about a document file
    func getMetadata(from url: URL) -> DocumentMetadata? {
        let fileManager = FileManager.default
        
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        
        let fileSize = attributes[.size] as? Int ?? 0
        let fileName = url.lastPathComponent
        let mimeType = mimeTypeForExtension(url.pathExtension)
        
        var pageCount: Int? = nil
        if url.pathExtension.lowercased() == "pdf",
           let pdfDoc = AdaPDF(url: url) {
            pageCount = pdfDoc.pageCount
        }
        
        // Get a short preview of the text content
        let textPreview: String?
        if let fullText = extractText(from: url) {
            textPreview = String(fullText.prefix(500))
        } else {
            textPreview = nil
        }
        
        return DocumentMetadata(
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            pageCount: pageCount,
            textPreview: textPreview
        )
    }
    
    // MARK: - MIME Type Helpers
    
    /// Get MIME type from file extension
    func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":
            return "application/pdf"
        case "txt":
            return "text/plain"
        case "md":
            return "text/markdown"
        case "json":
            return "application/json"
        case "csv":
            return "text/csv"
        case "xml":
            return "application/xml"
        case "html", "htm":
            return "text/html"
        case "css":
            return "text/css"
        case "js":
            return "application/javascript"
        case "doc":
            return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":
            return "application/vnd.ms-excel"
        case "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":
            return "application/vnd.ms-powerpoint"
        case "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip":
            return "application/zip"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        default:
            return FilesystemTools.mimeType(forPath: "file.\(ext)")
        }
    }

    private func isTextLikeMimeType(_ mimeType: String) -> Bool {
        let normalized = mimeType
            .lowercased()
            .split(separator: ";")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? mimeType.lowercased()

        if normalized.hasPrefix("text/") {
            return true
        }

        let textLikeApplicationTypes: Set<String> = [
            "application/json",
            "application/javascript",
            "application/x-javascript",
            "application/typescript",
            "application/xml",
            "application/yaml",
            "application/x-yaml",
            "application/toml",
            "application/x-toml",
            "application/x-sh",
            "application/x-shellscript",
            "application/sql",
            "application/graphql",
            "application/ld+json",
            "application/manifest+json"
        ]

        return textLikeApplicationTypes.contains(normalized)
            || normalized.hasSuffix("+json")
            || normalized.hasSuffix("+xml")
            || normalized.hasSuffix("+yaml")
    }
}
