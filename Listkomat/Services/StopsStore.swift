import Foundation

/// Loads the bundled static stops. No network — refreshed at build time via
/// scripts/generate-brno-stops.sh.
enum StopsStore {
    static func decode(_ data: Data) throws -> [Stop] {
        try JSONDecoder().decode([Stop].self, from: data)
    }

    /// Brno stops from the app bundle (empty if missing).
    static func brno() -> [Stop] {
        guard let url = Bundle.main.url(forResource: "brno-stops", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }
}
