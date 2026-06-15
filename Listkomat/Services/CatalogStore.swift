import Foundation

/// Holds the ticket catalog. v1 loads the bundled copy; remote fetch + cache
/// (with this bundled copy as offline fallback) arrives in M5.
@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var catalog: TicketCatalog

    init() {
        self.catalog = Self.loadBundled()
    }

    var cities: [City] { catalog.cities }

    func city(forKey key: String) -> City? {
        catalog.cities.first { $0.key == key }
    }

    static func loadBundled(bundle: Bundle = .main) -> TicketCatalog {
        guard let url = bundle.url(forResource: "tickets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(TicketCatalog.self, from: data)
        else {
            return .empty
        }
        return catalog
    }
}
