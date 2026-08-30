import Foundation
#if canImport(AppKit)
import PDFKit
import AppKit
#endif

// MARK: - Document Generator Service

/// Service for generating PDF, Excel (CSV), and Word (RTF) documents
actor DocumentGeneratorService {
    static let shared = DocumentGeneratorService()
    
    private init() {}
    
    // MARK: - Main Generation Entry Point
    
    /// Generate a document based on the provided specification
    /// - Returns: Tuple of (file data, filename, MIME type)
    func generate(args: GenerateDocumentArguments) throws -> (data: Data, filename: String, mimeType: String) {
        guard let docType = DocumentType(rawValue: args.documentType.lowercased()) else {
            throw DocumentGeneratorError.invalidDocumentType(args.documentType)
        }
        
        // Handle fullscreen image layout for PDFs
        if docType == .pdf && args.layout?.lowercased() == "fullscreen_image" {
            guard let imageFilenames = args.imageFilenames, !imageFilenames.isEmpty else {
                throw DocumentGeneratorError.noContent
            }
            let data = try generateFullscreenImagePDF(imageFilenames: imageFilenames)
            let filename = "\(sanitizeFilename(args.title ?? "images")).pdf"
            print("[DocumentGenerator] Generated fullscreen image PDF: \(filename) (\(imageFilenames.count) pages, \(data.count) bytes)")
            return (data, filename, docType.mimeType)
        }
        
        // Standard document generation requires a title
        let title = args.title ?? "Document"
        let sanitizedTitle = sanitizeFilename(title)
        let filename = "\(sanitizedTitle).\(docType.fileExtension)"
        
        let data: Data
        switch docType {
        case .pdf:
            data = try generatePDF(title: title, sections: args.sections, tableData: args.tableData)
        case .excel:
            data = try generateCSV(title: title, sections: args.sections, tableData: args.tableData)
        case .word:
            data = try generateRTF(title: title, sections: args.sections, tableData: args.tableData)
        }
        
        print("[DocumentGenerator] Generated \(docType.rawValue): \(filename) (\(data.count) bytes)")
        return (data, filename, docType.mimeType)
    }
    
    // MARK: - PDF Generation
    
    /// Generate a fullscreen image PDF (no margins, one page per image)
    #if canImport(AppKit)

    private func generateFullscreenImagePDF(imageFilenames: [String]) throws -> Data {
        let documentsDir = StoragePaths.dataRoot
        
        let pageWidth: CGFloat = 612  // US Letter
        let pageHeight: CGFloat = 792
        
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentGeneratorError.pdfCreationFailed
        }
        
        // Create one page per image
        for imageFilename in imageFilenames {
            let possiblePaths = [
                documentsDir.appendingPathComponent("documents").appendingPathComponent(imageFilename),
                documentsDir.appendingPathComponent("images").appendingPathComponent(imageFilename)
            ]
            
            var imageData: Data?
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path.path),
                   let data = try? Data(contentsOf: path) {
                    imageData = data
                    break
                }
            }
            
            guard let data = imageData,
                  let nsImage = NSImage(data: data),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw DocumentGeneratorError.imageNotFound(imageFilename)
            }
            
            // Calculate how to scale image to fill page (cover mode)
            let imageWidth = CGFloat(cgImage.width)
            let imageHeight = CGFloat(cgImage.height)
            let imageAspect = imageWidth / imageHeight
            let pageAspect = pageWidth / pageHeight
            
            var drawRect: CGRect
            if imageAspect > pageAspect {
                // Image is wider than page - fit height, crop width
                let scaledWidth = pageHeight * imageAspect
                let xOffset = (pageWidth - scaledWidth) / 2
                drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: pageHeight)
            } else {
                // Image is taller than page - fit width, crop height
                let scaledHeight = pageWidth / imageAspect
                let yOffset = (pageHeight - scaledHeight) / 2
                drawRect = CGRect(x: 0, y: yOffset, width: pageWidth, height: scaledHeight)
            }
            
            pdfContext.beginPage(mediaBox: &mediaBox)
            pdfContext.draw(cgImage, in: drawRect)
            pdfContext.endPage()
            
            print("[DocumentGenerator] Added fullscreen page for: \(imageFilename)")
        }
        
        pdfContext.closePDF()
        
        return pdfData as Data
    }
    
    private func generatePDF(title: String, sections: [DocumentSection]?, tableData: TableData?) throws -> Data {
        let pageWidth: CGFloat = 612  // US Letter width in points
        let pageHeight: CGFloat = 792 // US Letter height in points
        let margin: CGFloat = 50
        let contentWidth = pageWidth - (margin * 2)
        
        let pdfData = NSMutableData()
        
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentGeneratorError.pdfCreationFailed
        }
        
        var currentY: CGFloat = pageHeight - margin
        var pageStarted = false
        
        func startNewPage() {
            if pageStarted {
                pdfContext.endPage()
            }
            pdfContext.beginPage(mediaBox: &mediaBox)
            pageStarted = true
            currentY = pageHeight - margin
        }
        
        func checkPageBreak(neededHeight: CGFloat) {
            if currentY - neededHeight < margin {
                startNewPage()
            }
        }
        
        // Start first page
        startNewPage()
        
        // Title (wrapped)
        currentY = drawWrappedText(title, in: pdfContext, at: margin, y: currentY, 
                                   width: contentWidth, fontSize: 24, bold: true,
                                   checkPageBreak: checkPageBreak, startNewPage: startNewPage)
        currentY -= 20 // Space after title
        
        // Sections
        if let sections = sections {
            for section in sections {
                // Heading (wrapped)
                if let heading = section.heading, !heading.isEmpty {
                    checkPageBreak(neededHeight: 30)
                    currentY = drawWrappedText(heading, in: pdfContext, at: margin, y: currentY,
                                               width: contentWidth, fontSize: 16, bold: true,
                                               checkPageBreak: checkPageBreak, startNewPage: startNewPage)
                    currentY -= 10
                }
                
                // Body text
                if let body = section.body, !body.isEmpty {
                    currentY = drawWrappedText(body, in: pdfContext, at: margin, y: currentY, 
                                               width: contentWidth, fontSize: 12,
                                               checkPageBreak: checkPageBreak, startNewPage: startNewPage)
                    currentY -= 10
                }
                
                // Bullet points
                if let bullets = section.bulletPoints, !bullets.isEmpty {
                    for bullet in bullets {
                        let bulletText = "• \(bullet)"
                        currentY = drawWrappedText(bulletText, in: pdfContext, at: margin + 15, y: currentY,
                                                   width: contentWidth - 15, fontSize: 12,
                                                   checkPageBreak: checkPageBreak, startNewPage: startNewPage)
                        currentY -= 5
                    }
                    currentY -= 5
                }
                
                // Inline table
                if let table = section.table {
                    currentY = drawTable(table, in: pdfContext, at: margin, y: currentY,
                                        width: contentWidth, checkPageBreak: checkPageBreak,
                                        startNewPage: startNewPage)
                    currentY -= 15
                }
                
                // Image
                if let imageRef = section.image {
                    currentY = drawImage(imageRef, in: pdfContext, at: margin, y: currentY,
                                        contentWidth: contentWidth, pageWidth: pageWidth,
                                        checkPageBreak: checkPageBreak, startNewPage: startNewPage)
                    currentY -= 15
                }
                
                currentY -= 10 // Space between sections
            }
        }
        
        // Standalone table data (for simple spreadsheet-like PDFs)
        if let tableData = tableData {
            currentY = drawTable(tableData, in: pdfContext, at: margin, y: currentY,
                                width: contentWidth, checkPageBreak: checkPageBreak,
                                startNewPage: startNewPage)
        }
        
        pdfContext.endPage()
        pdfContext.closePDF()
        
        return pdfData as Data
    }
    
    private func drawWrappedText(_ text: String, in context: CGContext, at x: CGFloat, y: CGFloat,
                                  width: CGFloat, fontSize: CGFloat, bold: Bool = false,
                                  checkPageBreak: (CGFloat) -> Void,
                                  startNewPage: () -> Void) -> CGFloat {
        var currentY = y
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        
        let lineHeight = fontSize * 1.4
        
        // Helper to measure text width
        func measureWidth(_ str: String) -> CGFloat {
            return NSAttributedString(string: str, attributes: attributes).size().width
        }
        
        // Helper to draw a single line
        func drawLine(_ lineText: String) {
            checkPageBreak(lineHeight)
            currentY -= lineHeight
            
            let lineString = NSAttributedString(string: lineText, attributes: attributes)
            let line = CTLineCreateWithAttributedString(lineString)
            context.textPosition = CGPoint(x: x, y: currentY)
            CTLineDraw(line, context)
        }
        
        // Split by newlines first to preserve paragraph structure
        let paragraphs = text.components(separatedBy: .newlines)
        
        for paragraph in paragraphs {
            if paragraph.isEmpty {
                currentY -= lineHeight * 0.5  // Half line for empty paragraphs
                continue
            }
            
            let words = paragraph.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            var currentLine = ""
            
            for word in words {
                // Check if this word alone is too long
                if measureWidth(word) > width {
                    // Draw current line first if not empty
                    if !currentLine.isEmpty {
                        drawLine(currentLine)
                        currentLine = ""
                    }
                    
                    // Break long word into chunks that fit
                    var remainingWord = word
                    while !remainingWord.isEmpty {
                        var chunk = ""
                        for char in remainingWord {
                            let testChunk = chunk + String(char)
                            if measureWidth(testChunk) > width && !chunk.isEmpty {
                                break
                            }
                            chunk = testChunk
                        }
                        drawLine(chunk)
                        remainingWord = String(remainingWord.dropFirst(chunk.count))
                    }
                    continue
                }
                
                let testLine = currentLine.isEmpty ? word : "\(currentLine) \(word)"
                
                if measureWidth(testLine) > width && !currentLine.isEmpty {
                    // Draw current line and start new one with this word
                    drawLine(currentLine)
                    currentLine = word
                } else {
                    currentLine = testLine
                }
            }
            
            // Draw remaining text in current line
            if !currentLine.isEmpty {
                drawLine(currentLine)
            }
        }
        
        return currentY
    }

    
    private func drawTable(_ table: TableData, in context: CGContext, at x: CGFloat, y: CGFloat,
                          width: CGFloat, checkPageBreak: (CGFloat) -> Void,
                          startNewPage: () -> Void) -> CGFloat {
        var currentY = y
        let rowHeight: CGFloat = 25
        let padding: CGFloat = 5
        
        // Calculate column count and width
        let columnCount = max(table.headers?.count ?? 0, table.rows.first?.count ?? 1)
        let columnWidth = width / CGFloat(columnCount)
        
        let headerFont = NSFont.boldSystemFont(ofSize: 11)
        let cellFont = NSFont.systemFont(ofSize: 11)
        
        // Draw headers if present
        if let headers = table.headers, !headers.isEmpty {
            checkPageBreak(rowHeight)
            currentY -= rowHeight
            
            // Header background
            context.setFillColor(NSColor.lightGray.withAlphaComponent(0.3).cgColor)
            context.fill(CGRect(x: x, y: currentY, width: width, height: rowHeight))
            
            // Header text
            for (index, header) in headers.enumerated() {
                let cellX = x + CGFloat(index) * columnWidth + padding
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: headerFont,
                    .foregroundColor: NSColor.black
                ]
                let attrString = NSAttributedString(string: header, attributes: attributes)
                let line = CTLineCreateWithAttributedString(attrString)
                context.textPosition = CGPoint(x: cellX, y: currentY + 7)
                CTLineDraw(line, context)
            }
            
            // Header border
            context.setStrokeColor(NSColor.gray.cgColor)
            context.setLineWidth(0.5)
            context.stroke(CGRect(x: x, y: currentY, width: width, height: rowHeight))
        }
        
        // Draw rows
        for row in table.rows {
            checkPageBreak(rowHeight)
            currentY -= rowHeight
            
            for (index, cell) in row.enumerated() {
                let cellX = x + CGFloat(index) * columnWidth + padding
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: cellFont,
                    .foregroundColor: NSColor.black
                ]
                
                // Truncate if too long
                var displayText = cell
                let maxChars = Int(columnWidth / 7)
                if displayText.count > maxChars {
                    displayText = String(displayText.prefix(maxChars - 2)) + "..."
                }
                
                let attrString = NSAttributedString(string: displayText, attributes: attributes)
                let line = CTLineCreateWithAttributedString(attrString)
                context.textPosition = CGPoint(x: cellX, y: currentY + 7)
                CTLineDraw(line, context)
            }
            
            // Row border
            context.setStrokeColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(0.25)
            context.stroke(CGRect(x: x, y: currentY, width: width, height: rowHeight))
        }
        
        return currentY
    }
    
    private func drawImage(_ imageRef: ImageReference, in context: CGContext, at margin: CGFloat, y: CGFloat,
                          contentWidth: CGFloat, pageWidth: CGFloat,
                          checkPageBreak: (CGFloat) -> Void,
                          startNewPage: () -> Void) -> CGFloat {
        var currentY = y
        
        // Try to find the image in documents or images directories
        let documentsDir = StoragePaths.dataRoot
        
        let possiblePaths = [
            documentsDir.appendingPathComponent("documents").appendingPathComponent(imageRef.filename),
            documentsDir.appendingPathComponent("images").appendingPathComponent(imageRef.filename)
        ]
        
        var imageData: Data?
        var foundPath: URL?
        
        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path.path),
               let data = try? Data(contentsOf: path) {
                imageData = data
                foundPath = path
                break
            }
        }
        
        guard let data = imageData,
              let nsImage = NSImage(data: data),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            // Draw placeholder text if image not found
            let errorText = "[Image not found: \(imageRef.filename)]"
            let regularFont = NSFont.systemFont(ofSize: 10)
            let font = NSFontManager.shared.convert(regularFont, toHaveTrait: .italicFontMask)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.gray
            ]
            checkPageBreak(15)
            currentY -= 15
            let attrString = NSAttributedString(string: errorText, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrString)
            context.textPosition = CGPoint(x: margin, y: currentY)
            CTLineDraw(line, context)
            return currentY
        }
        
        // Calculate image dimensions
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        let aspectRatio = originalHeight / originalWidth
        
        // Calculate target width (percentage of content width, default 50%)
        let widthPercent = min(100, max(10, imageRef.width ?? 50))
        var targetWidth = contentWidth * CGFloat(widthPercent / 100.0)
        var targetHeight = targetWidth * aspectRatio
        
        // Calculate available content height on a page
        let pageHeight: CGFloat = 792 // US Letter
        let bottomMargin: CGFloat = 50
        let maxContentHeight = pageHeight - (2 * bottomMargin) - 30 // Leave room for caption
        
        // If image is taller than page can hold, scale it down
        if targetHeight > maxContentHeight {
            targetHeight = maxContentHeight
            targetWidth = targetHeight / aspectRatio
        }
        
        // Check if we need a new page - if image won't fit, start fresh
        let spaceNeeded = targetHeight + 25 // +25 for caption
        if currentY - spaceNeeded < bottomMargin {
            // Start a new page
            startNewPage()
            currentY = pageHeight - bottomMargin // Reset to top of new page
        }
        
        // Calculate X position based on alignment
        let imageX: CGFloat
        switch imageRef.alignment?.lowercased() {
        case "left":
            imageX = margin
        case "right":
            imageX = pageWidth - margin - targetWidth
        default: // center
            imageX = margin + (contentWidth - targetWidth) / 2
        }
        
        // Draw the image
        currentY -= targetHeight
        let imageRect = CGRect(x: imageX, y: currentY, width: targetWidth, height: targetHeight)
        context.draw(cgImage, in: imageRect)
        
        // Draw caption if present
        if let caption = imageRef.caption, !caption.isEmpty {
            currentY -= 5
            let regularCaptionFont = NSFont.systemFont(ofSize: 10)
            let captionFont = NSFontManager.shared.convert(regularCaptionFont, toHaveTrait: .italicFontMask)
            let captionAttributes: [NSAttributedString.Key: Any] = [
                .font: captionFont,
                .foregroundColor: NSColor.darkGray
            ]
            let captionString = NSAttributedString(string: caption, attributes: captionAttributes)
            let captionWidth = captionString.size().width
            let captionHeight = captionString.size().height
            
            // Caption should fit since we reserved space
            currentY -= captionHeight
            
            // Center caption under image
            let captionX = imageX + (targetWidth - captionWidth) / 2
            let captionLine = CTLineCreateWithAttributedString(captionString)
            context.textPosition = CGPoint(x: max(margin, captionX), y: currentY)
            CTLineDraw(captionLine, context)
        }
        
        print("[DocumentGenerator] Drew image: \(imageRef.filename) at \(Int(targetWidth))x\(Int(targetHeight))")
        return currentY
    }
    
    // MARK: - Excel (CSV) Generation
    
    #else

    // Linux: CoreGraphics/AppKit text layout is unavailable. Image-per-page
    // PDFs go through ImageMagick; text-layout PDFs are declined with a
    // pointer to the pdf skill (python), which is the richer path anyway.

    private func generateFullscreenImagePDF(imageFilenames: [String]) throws -> Data {
        let documentsDir = StoragePaths.dataRoot
        var imagePaths: [String] = []
        for imageFilename in imageFilenames {
            let possiblePaths = [
                documentsDir.appendingPathComponent("documents").appendingPathComponent(imageFilename),
                documentsDir.appendingPathComponent("images").appendingPathComponent(imageFilename)
            ]
            guard let found = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw DocumentGeneratorError.imageNotFound(imageFilename)
            }
            imagePaths.append(found.path)
        }
        guard !imagePaths.isEmpty else { throw DocumentGeneratorError.noContent }

        let convert: (path: String, prefix: [String])
        if let magick = PlatformBinary.find("magick") {
            convert = (magick, ["convert"])
        } else if let direct = PlatformBinary.find("convert") {
            convert = (direct, [])
        } else {
            throw DocumentGeneratorError.pdfToolMissing
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ada-imgpdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        guard PlatformBinary.run(convert.path, convert.prefix + imagePaths + [out.path], timeout: 300) != nil,
              let data = try? Data(contentsOf: out) else {
            throw DocumentGeneratorError.pdfCreationFailed
        }
        return data
    }

    private func generatePDF(title: String, sections: [DocumentSection]?, tableData: TableData?) throws -> Data {
        throw DocumentGeneratorError.pdfLayoutUnavailable
    }

    #endif

    private func generateCSV(title: String, sections: [DocumentSection]?, tableData: TableData?) throws -> Data {
        var csvLines: [String] = []
        
        // If we have tableData, use it directly
        if let tableData = tableData {
            // Headers
            if let headers = tableData.headers, !headers.isEmpty {
                csvLines.append(headers.map { escapeCSV($0) }.joined(separator: ","))
            }
            
            // Rows
            for row in tableData.rows {
                csvLines.append(row.map { escapeCSV($0) }.joined(separator: ","))
            }
        }
        // Otherwise, try to extract table from sections
        else if let sections = sections {
            // Add title as first row
            csvLines.append(escapeCSV(title))
            csvLines.append("")
            
            for section in sections {
                if let heading = section.heading {
                    csvLines.append(escapeCSV(heading))
                }
                
                if let table = section.table {
                    if let headers = table.headers {
                        csvLines.append(headers.map { escapeCSV($0) }.joined(separator: ","))
                    }
                    for row in table.rows {
                        csvLines.append(row.map { escapeCSV($0) }.joined(separator: ","))
                    }
                }
                
                if let bullets = section.bulletPoints {
                    for bullet in bullets {
                        csvLines.append(escapeCSV(bullet))
                    }
                }
                
                csvLines.append("")
            }
        } else {
            // Just title
            csvLines.append(escapeCSV(title))
        }
        
        let csvContent = csvLines.joined(separator: "\n")
        guard let data = csvContent.data(using: .utf8) else {
            throw DocumentGeneratorError.encodingFailed
        }
        
        return data
    }
    
    private func escapeCSV(_ value: String) -> String {
        var escaped = value
        // If contains comma, newline, or quote, wrap in quotes and escape internal quotes
        if escaped.contains(",") || escaped.contains("\n") || escaped.contains("\"") {
            escaped = escaped.replacingOccurrences(of: "\"", with: "\"\"")
            escaped = "\"\(escaped)\""
        }
        return escaped
    }
    
    // MARK: - Word (RTF) Generation
    
    private func generateRTF(title: String, sections: [DocumentSection]?, tableData: TableData?) throws -> Data {
        var rtf = "{\\rtf1\\ansi\\deff0\n"
        
        // Font table
        rtf += "{\\fonttbl{\\f0 Helvetica;}{\\f1 Helvetica-Bold;}}\n"
        
        // Title - bold, large
        rtf += "{\\f1\\fs36 \(escapeRTF(title))}\\par\\par\n"
        
        // Sections
        if let sections = sections {
            for section in sections {
                // Heading
                if let heading = section.heading, !heading.isEmpty {
                    rtf += "{\\f1\\fs28 \(escapeRTF(heading))}\\par\n"
                }
                
                // Body
                if let body = section.body, !body.isEmpty {
                    rtf += "{\\f0\\fs24 \(escapeRTF(body))}\\par\n"
                }
                
                // Bullet points
                if let bullets = section.bulletPoints, !bullets.isEmpty {
                    for bullet in bullets {
                        rtf += "{\\f0\\fs24 \\bullet  \(escapeRTF(bullet))}\\par\n"
                    }
                }
                
                // Table
                if let table = section.table {
                    rtf += generateRTFTable(table)
                }
                
                rtf += "\\par\n"
            }
        }
        
        // Standalone table
        if let tableData = tableData {
            rtf += generateRTFTable(tableData)
        }
        
        rtf += "}"
        
        guard let data = rtf.data(using: .utf8) else {
            throw DocumentGeneratorError.encodingFailed
        }
        
        return data
    }
    
    private func generateRTFTable(_ table: TableData) -> String {
        var rtf = ""
        let columnCount = max(table.headers?.count ?? 0, table.rows.first?.count ?? 1)
        let cellWidth = 2000 // twips (1/20 of a point)
        
        // Headers
        if let headers = table.headers, !headers.isEmpty {
            rtf += "\\trowd"
            for i in 0..<headers.count {
                rtf += "\\cellx\((i + 1) * cellWidth)"
            }
            rtf += "\n"
            for header in headers {
                rtf += "{\\f1\\fs22 \(escapeRTF(header))}\\cell"
            }
            rtf += "\\row\n"
        }
        
        // Rows
        for row in table.rows {
            rtf += "\\trowd"
            for i in 0..<columnCount {
                rtf += "\\cellx\((i + 1) * cellWidth)"
            }
            rtf += "\n"
            for cell in row {
                rtf += "{\\f0\\fs22 \(escapeRTF(cell))}\\cell"
            }
            rtf += "\\row\n"
        }
        
        return rtf
    }
    
    private func escapeRTF(_ text: String) -> String {
        var escaped = text
        escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "{", with: "\\{")
        escaped = escaped.replacingOccurrences(of: "}", with: "\\}")
        escaped = escaped.replacingOccurrences(of: "\n", with: "\\par ")
        return escaped
    }
    
    // MARK: - Helpers
    
    private func sanitizeFilename(_ filename: String) -> String {
        // Remove or replace invalid filename characters
        let invalidChars = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        let sanitized = filename.components(separatedBy: invalidChars).joined(separator: "_")
        // Limit length
        let maxLength = 50
        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        return sanitized.isEmpty ? "document" : sanitized
    }
}

// MARK: - Errors

enum DocumentGeneratorError: LocalizedError {
    case invalidDocumentType(String)
    case pdfCreationFailed
    case encodingFailed
    case noContent
    case imageNotFound(String)
    case pdfToolMissing
    case pdfLayoutUnavailable
    
    var errorDescription: String? {
        switch self {
        case .pdfToolMissing:
            return "ImageMagick is required for image PDFs on Linux. Install it (e.g. sudo apt install imagemagick) and retry."
        case .pdfLayoutUnavailable:
            return "Native text-layout PDF generation is unavailable on Linux. Use the pdf skill (python) to produce the PDF instead."
        case .invalidDocumentType(let type):
            return "Invalid document type: '\(type)'. Use 'pdf', 'excel', or 'word'."
        case .pdfCreationFailed:
            return "Failed to create PDF document."
        case .encodingFailed:
            return "Failed to encode document content."
        case .noContent:
            return "No content provided for the document."
        case .imageNotFound(let filename):
            return "Image file not found: '\(filename)'. Use glob or list_dir to find available files."
        }
    }
}
