import Foundation

/// Loads the bundled static stops. No network — refreshed at build time via
/// scripts/generate-brno-stops.sh.
enum StopsStore {
    static func decode(_ data: Data) throws -> [Stop] {
        try JSONDecoder().decode([Stop].self, from: data)
    }

    /// Brno stops from the app bundle (empty if missing).
    static func brno() -> [Stop] { bundled("brno-stops") }

    /// Prague stops from the app bundle (empty if missing).
    /// Regenerated via scripts/generate-prague-stops.sh (PID GTFS, CC-BY 4.0).
    static func prague() -> [Stop] { bundled("prague-stops") }

    private static func bundled(_ resource: String) -> [Stop] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }
}
