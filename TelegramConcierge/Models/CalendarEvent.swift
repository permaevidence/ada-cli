import Foundation

// MARK: - Calendar Event Model

struct CalendarEvent: Codable, Identifiable {
    let id: UUID
    var title: String
    var datetime: Date
    var notes: String?
    let createdAt: Date
    
    init(title: String, datetime: Date, notes: String? = nil) {
        self.id = UUID()
        self.title = title
        self.datetime = datetime
        self.notes = notes
        self.createdAt = Date()
    }
}
