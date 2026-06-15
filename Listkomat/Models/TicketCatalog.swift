import Foundation

/// Top-level catalog, decoded from the bundled (and later remote) tickets.json.
struct TicketCatalog: Codable {
    let version: Int
    let updatedAt: String
    let cities: [City]

    static let empty = TicketCatalog(version: 0, updatedAt: "", cities: [])
}
