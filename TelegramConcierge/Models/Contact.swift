import Foundation

// MARK: - Contact Model

struct Contact: Codable, Identifiable {
    let id: UUID
    var firstName: String
    var lastName: String?
    var email: String?
    var phone: String?
    var organization: String?
    let createdAt: Date
    
    init(
        id: UUID = UUID(),
        firstName: String,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        organization: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.organization = organization
        self.createdAt = createdAt
    }
    
    /// Full display name combining first and last name
    var fullName: String {
        if let lastName = lastName, !lastName.isEmpty {
            return "\(firstName) \(lastName)"
        }
        return firstName
    }
}
