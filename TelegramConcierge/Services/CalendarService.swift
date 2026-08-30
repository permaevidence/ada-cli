import Foundation

// MARK: - Calendar Service

/// Singleton actor that manages calendar event persistence
actor CalendarService {
    static let shared = CalendarService()
    
    private var events: [CalendarEvent] = []
    
    private let calendarFileURL: URL = {
        let folder = StoragePaths.dataRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("calendar.json")
    }()
    
    private init() {
        loadEvents()
    }
    
    // MARK: - Public API

    /// Test seam: when set, saveEvents throws instead of writing, so the
    /// selftest can pin the mutate-rollback contract without real disk
    /// failures. Production never sets this.
    private var saveFailureForTesting = false
    func setSaveFailureForTesting(_ on: Bool) { saveFailureForTesting = on }

    /// Add a new calendar event and persist it. Throws (with the in-memory
    /// state rolled back) when persistence fails — a mutation the disk never
    /// saw must not be reported as saved, or it silently vanishes on restart.
    func addEvent(title: String, datetime: Date, notes: String?) throws -> CalendarEvent {
        let event = CalendarEvent(title: title, datetime: datetime, notes: notes)
        let before = events
        events.append(event)
        do {
            try saveEvents()
        } catch {
            events = before
            throw error
        }
        print("[CalendarService] Added event '\(title)' for \(datetime)")
        return event
    }
    
    /// Get events, optionally including past events
    /// By default only returns future events to keep context window small
    func getEvents(includePast: Bool = false) -> [CalendarEvent] {
        let now = Date()
        if includePast {
            return events.sorted { $0.datetime < $1.datetime }
        } else {
            return events.filter { $0.datetime >= now }.sorted { $0.datetime < $1.datetime }
        }
    }
    
    /// Get only past events
    func getPastEvents() -> [CalendarEvent] {
        let now = Date()
        return events.filter { $0.datetime < now }.sorted { $0.datetime > $1.datetime }
    }
    
    /// Update an existing event. false = not found; throws = persistence
    /// failed (in-memory state rolled back).
    func updateEvent(id: UUID, title: String?, datetime: Date?, notes: String?) throws -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            print("[CalendarService] Event \(id) not found for update")
            return false
        }

        let before = events
        if let title = title {
            events[index].title = title
        }
        if let datetime = datetime {
            events[index].datetime = datetime
        }
        if let notes = notes {
            events[index].notes = notes
        }

        do {
            try saveEvents()
        } catch {
            events = before
            throw error
        }
        print("[CalendarService] Updated event \(id)")
        return true
    }

    /// Delete an event. false = not found; throws = persistence failed
    /// (in-memory state rolled back).
    func deleteEvent(id: UUID) throws -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            print("[CalendarService] Event \(id) not found for deletion")
            return false
        }

        let before = events
        let event = events.remove(at: index)
        do {
            try saveEvents()
        } catch {
            events = before
            throw error
        }
        print("[CalendarService] Deleted event '\(event.title)'")
        return true
    }
    
    /// Get a specific event by ID
    func getEvent(id: UUID) -> CalendarEvent? {
        events.first { $0.id == id }
    }

    enum EventIdResolution: Equatable {
        case success(UUID)
        case failure(String)
    }

    /// Resolves a model-supplied event id to a stored event UUID. Accepts the
    /// full UUID or a unique prefix of ≥8 characters — calendar context shows
    /// events as `[id: <8 chars>...]`, so the model should not need a view
    /// round-trip before editing or deleting.
    func resolveEventId(_ raw: String) -> EventIdResolution {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: trimmed) { return .success(uuid) }
        guard trimmed.count >= 8 else {
            return .failure("event_id must be a full UUID or a prefix of at least 8 characters")
        }
        let matches = events.filter { $0.id.uuidString.lowercased().hasPrefix(trimmed.lowercased()) }
        switch matches.count {
        case 1: return .success(matches[0].id)
        case 0: return .failure("no event found with id prefix '\(trimmed)' — use action='view' (include_past if needed) to list events")
        default: return .failure("id prefix '\(trimmed)' matches \(matches.count) events — provide more characters")
        }
    }
    
    /// Get count of upcoming events
    func upcomingCount() -> Int {
        let now = Date()
        return events.filter { $0.datetime >= now }.count
    }
    
    // MARK: - Calendar Context for System Prompt
    
    private var cachedContext: String?
    private var cacheInvalidated: Bool = true
    /// `startOfDay` at the moment `cachedContext` was rendered. Used to auto-
    /// invalidate the cache when the local day rolls over so "TODAY/TOMORROW"
    /// labels and the `>= startOfToday` event filter stay correct.
    private var cachedDay: Date?

    // Token thresholds (approximate: 4 chars per token)
    private let maxTokens = 4000
    private let triggerTokens = 5000
    private let charsPerToken = 4

    /// Get formatted calendar context for LLM system prompt
    /// Returns a string with today's and future events, auto-summarized if too long
    func getCalendarContextForSystemPrompt() -> String {
        let today = Calendar.current.startOfDay(for: Date())
        // Return cached if valid AND the local day hasn't rolled over since render.
        if !cacheInvalidated, let cached = cachedContext, cachedDay == today {
            return cached
        }

        let context = generateCalendarContext()
        cachedContext = context
        cachedDay = today
        cacheInvalidated = false
        return context
    }
    
    /// Invalidate cache when events change
    private func invalidateCache() {
        cacheInvalidated = true
        cachedContext = nil
        cachedDay = nil
    }
    
    /// Generate calendar context with progressive detail
    private func generateCalendarContext() -> String {
        let now = Date()
        let calendar = Calendar.current
        
        // Get future events (including today)
        let startOfToday = calendar.startOfDay(for: now)
        let futureEvents = events
            .filter { $0.datetime >= startOfToday }
            .sorted { $0.datetime < $1.datetime }
        
        guard !futureEvents.isEmpty else {
            return "📅 **Your Calendar**: No upcoming events."
        }
        
        // First pass: generate full detail version
        let fullContext = generateFullDetailContext(events: futureEvents, now: now, calendar: calendar)
        
        // Check if we need to compress
        let estimatedTokens = fullContext.count / charsPerToken
        if estimatedTokens <= triggerTokens {
            return fullContext
        }
        
        // Need to compress - use progressive detail
        return generateCompressedContext(events: futureEvents, now: now, calendar: calendar)
    }
    
    /// Generate full detail version of calendar
    private func generateFullDetailContext(events: [CalendarEvent], now: Date, calendar: Calendar) -> String {
        var lines: [String] = ["📅 **Your Calendar**:", ""]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        
        var currentDateString = ""
        
        for event in events {
            let eventDateString = dateFormatter.string(from: event.datetime)
            
            // Add date header if new day
            if eventDateString != currentDateString {
                if !currentDateString.isEmpty {
                    lines.append("")
                }
                
                // Mark today specially
                if calendar.isDateInToday(event.datetime) {
                    lines.append("**TODAY - \(eventDateString)**")
                } else if calendar.isDateInTomorrow(event.datetime) {
                    lines.append("**TOMORROW - \(eventDateString)**")
                } else {
                    lines.append("**\(eventDateString)**")
                }
                currentDateString = eventDateString
            }
            
            // Event details
            let timeStr = timeFormatter.string(from: event.datetime)
            var eventLine = "• \(timeStr): \(event.title)"
            if let notes = event.notes, !notes.isEmpty {
                eventLine += " — \(notes)"
            }
            eventLine += " [id: \(event.id.uuidString.prefix(8))...]"
            lines.append(eventLine)
        }
        
        return lines.joined(separator: "\n")
    }
    
    /// Generate compressed version with progressive detail
    private func generateCompressedContext(events: [CalendarEvent], now: Date, calendar: Calendar) -> String {
        var lines: [String] = ["📅 **Your Calendar** (summarized):", ""]
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        let weekFormatter = DateFormatter()
        weekFormatter.dateFormat = "'Week of' MMM d"
        
        // Boundaries
        let sevenDaysOut = calendar.date(byAdding: .day, value: 7, to: now)!
        let thirtyDaysOut = calendar.date(byAdding: .day, value: 30, to: now)!
        
        // Partition events
        let nearEvents = events.filter { $0.datetime < sevenDaysOut }
        let midEvents = events.filter { $0.datetime >= sevenDaysOut && $0.datetime < thirtyDaysOut }
        let farEvents = events.filter { $0.datetime >= thirtyDaysOut }
        
        // Near events: full detail
        var currentDateString = ""
        for event in nearEvents {
            let eventDateString = dateFormatter.string(from: event.datetime)
            
            if eventDateString != currentDateString {
                if !currentDateString.isEmpty { lines.append("") }
                if calendar.isDateInToday(event.datetime) {
                    lines.append("**TODAY - \(eventDateString)**")
                } else if calendar.isDateInTomorrow(event.datetime) {
                    lines.append("**TOMORROW - \(eventDateString)**")
                } else {
                    lines.append("**\(eventDateString)**")
                }
                currentDateString = eventDateString
            }
            
            let timeStr = timeFormatter.string(from: event.datetime)
            var eventLine = "• \(timeStr): \(event.title)"
            if let notes = event.notes, !notes.isEmpty {
                eventLine += " — \(notes)"
            }
            eventLine += " [id: \(event.id.uuidString.prefix(8))...]"
            lines.append(eventLine)
        }
        
        // Mid events: title + date only
        if !midEvents.isEmpty {
            lines.append("")
            lines.append("**Next 8-30 days:**")
            for event in midEvents {
                let dateStr = dateFormatter.string(from: event.datetime)
                lines.append("• \(dateStr): \(event.title) [id: \(event.id.uuidString.prefix(8))...]")
            }
        }
        
        // Far events: grouped by week
        if !farEvents.isEmpty {
            lines.append("")
            lines.append("**Beyond 30 days:**")
            
            // Group by week
            var weeklyGroups: [String: [CalendarEvent]] = [:]
            for event in farEvents {
                let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: event.datetime))!
                let weekKey = weekFormatter.string(from: weekStart)
                weeklyGroups[weekKey, default: []].append(event)
            }
            
            // Sort by date and output
            let sortedWeeks = weeklyGroups.keys.sorted { key1, key2 in
                weeklyGroups[key1]!.first!.datetime < weeklyGroups[key2]!.first!.datetime
            }
            
            for weekKey in sortedWeeks {
                let count = weeklyGroups[weekKey]!.count
                let titles = weeklyGroups[weekKey]!.prefix(2).map { $0.title }.joined(separator: ", ")
                if count > 2 {
                    lines.append("• \(weekKey): \(titles) +\(count - 2) more")
                } else {
                    lines.append("• \(weekKey): \(titles)")
                }
            }
        }
        
        // Ensure we're under the limit
        var result = lines.joined(separator: "\n")
        let maxChars = maxTokens * charsPerToken
        if result.count > maxChars {
            result = String(result.prefix(maxChars - 50)) + "\n... [calendar truncated, use manage_calendar with action='view' for full details]"
        }
        
        return result
    }
    
    // MARK: - Persistence
    
    private func loadEvents() {
        guard FileManager.default.fileExists(atPath: calendarFileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: calendarFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = try decoder.decode([CalendarEvent].self, from: data)
            print("[CalendarService] Loaded \(events.count) events")
            invalidateCache()
        } catch {
            print("[CalendarService] Failed to load events: \(error)")
        }
    }
    
    struct SaveFailureForTesting: LocalizedError {
        var errorDescription: String? { "simulated calendar persistence failure (test seam)" }
    }

    /// Atomic write; throws on failure so mutating callers can roll back and
    /// report honestly instead of claiming a save the disk never saw.
    private func saveEvents() throws {
        if saveFailureForTesting { throw SaveFailureForTesting() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(events)
        try data.write(to: calendarFileURL, options: [.atomic])
        invalidateCache()
    }
    
    // MARK: - Export/Import for Standalone Calendar Backup
    
    /// Get all events as JSON data for export
    func getEventsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(events)
    }
    
    /// Import events from JSON data (replaces all existing events)
    func importEvents(from data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let importedEvents = try decoder.decode([CalendarEvent].self, from: data)
        events = importedEvents
        try saveEvents()
        print("[CalendarService] Imported \(events.count) events")
    }

    /// Reload events after a Mind restore replaces the backing JSON file.
    func reloadFromDisk() {
        events.removeAll()
        invalidateCache()
        loadEvents()
    }
    
    /// Get count of all events (past + future)
    func totalEventCount() -> Int {
        events.count
    }
}
