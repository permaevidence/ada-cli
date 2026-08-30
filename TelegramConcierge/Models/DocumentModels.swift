import Foundation

// MARK: - Document Generation Models

/// Types of documents that can be generated
enum DocumentType: String, Codable {
    case pdf
    case excel
    case word
    
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .excel: return "csv"  // Using CSV for broad compatibility
        case .word: return "rtf"   // Using RTF for broad compatibility
        }
    }
    
    var mimeType: String {
        switch self {
        case .pdf: return "application/pdf"
        case .excel: return "text/csv"
        case .word: return "application/rtf"
        }
    }
}

// MARK: - Document Specification (from Gemini)

/// Complete document specification that Gemini provides
struct GenerateDocumentArguments: Codable {
    let documentType: String
    let title: String?  // Optional for fullscreen layouts
    let layout: String?  // "standard" (default) or "fullscreen_image"
    let imageFilenames: [String]?  // Image filenames for fullscreen_image layout (one page per image)
    
    // Internal storage for parsed data
    var sections: [DocumentSection]?
    var tableData: TableData?
    
    enum CodingKeys: String, CodingKey {
        case documentType = "document_type"
        case title
        case layout
        case imageFilenames = "image_filenames"
        case sections
        case tableData = "table_data"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documentType = try container.decode(String.self, forKey: .documentType)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        layout = try container.decodeIfPresent(String.self, forKey: .layout)
        
        // Handle image_filenames - can be array or single string
        if let filenames = try? container.decode([String].self, forKey: .imageFilenames) {
            imageFilenames = filenames
        } else if let singleFilename = try? container.decode(String.self, forKey: .imageFilenames) {
            imageFilenames = [singleFilename]
        } else {
            imageFilenames = nil
        }
        
        // Try to decode sections - could be array directly or JSON string
        if let directSections = try? container.decode([DocumentSection].self, forKey: .sections) {
            sections = directSections
        } else if let sectionsString = try? container.decode(String.self, forKey: .sections),
                  let sectionsData = sectionsString.data(using: .utf8),
                  let parsedSections = try? JSONDecoder().decode([DocumentSection].self, from: sectionsData) {
            sections = parsedSections
        } else {
            sections = nil
        }
        
        // Try to decode tableData - could be object directly or JSON string
        if let directTableData = try? container.decode(TableData.self, forKey: .tableData) {
            tableData = directTableData
        } else if let tableDataString = try? container.decode(String.self, forKey: .tableData),
                  let tableDataBytes = tableDataString.data(using: .utf8),
                  let parsedTableData = try? JSONDecoder().decode(TableData.self, from: tableDataBytes) {
            tableData = parsedTableData
        } else {
            tableData = nil
        }
    }
}

/// A section in a PDF or Word document
struct DocumentSection: Codable {
    let heading: String?
    let body: String?
    let bulletPoints: [String]?
    let table: TableData?
    let image: ImageReference?
    
    enum CodingKeys: String, CodingKey {
        case heading
        case body
        case bulletPoints = "bullet_points"
        case table
        case image
    }
}

/// Reference to an image file with layout options
struct ImageReference: Codable {
    let filename: String           // File from documents/images directory
    let caption: String?           // Optional caption below image
    let width: Double?             // Optional: width as percentage of page (10-100), default 50
    let alignment: String?         // Optional: "left", "center", "right", default "center"
    
    enum CodingKeys: String, CodingKey {
        case filename
        case caption
        case width
        case alignment
    }
}

/// Table data for Excel sheets or inline tables
struct TableData: Codable {
    let headers: [String]?
    let rows: [[String]]
}

// MARK: - Generation Result

struct GenerateDocumentResult: Codable {
    let success: Bool
    let message: String
    let filename: String?
    let fileSize: Int?
    let documentType: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case message
        case filename
        case fileSize = "file_size"
        case documentType = "document_type"
    }
}
