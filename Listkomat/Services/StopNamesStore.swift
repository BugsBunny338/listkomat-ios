import Foundation

/// Maps the live feed's numeric stop id (FinalStopID) to a stop name, so a
/// vehicle's destination can be shown. Bundled (Resources/brno-stop-names.json),
/// produced by scripts/generate-brno-stops.sh.
enum StopNamesStore {
    static func decode(_ data: Data) throws -> [Int: String] {
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    static func brno() -> [Int: String] {
        guard let url = Bundle.main.url(forResource: "brno-stop-names", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decode(data)) ?? [:]
    }
}
