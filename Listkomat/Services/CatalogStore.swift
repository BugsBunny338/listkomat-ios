import Foundation

/// Holds the ticket catalog with a three-tier source chain:
/// remote (freshest) → on-disk cache (last good) → bundled (offline fallback).
/// A wrong/stale code can thus be fixed by editing the public catalog JSON,
/// with no App Store release.
@MainActor
final class CatalogStore: ObservableObject {
    @Published private(set) var catalog: TicketCatalog
    /// True when the last remote refresh failed (offline / unreachable) — we're
    /// then showing cached or bundled prices.
    @Published private(set) var refreshFailed = false

    private let remoteURL = URL(string:
        "https://raw.githubusercontent.com/BugsBunny338/listkomat-catalog/main/tickets.json")!

    init() {
        self.catalog = Self.loadCachedOrBundled()
    }

    var cities: [City] { catalog.cities }

    func city(forKey key: String) -> City? {
        catalog.cities.first { $0.key == key }
    }

    /// Fetch the remote catalog; adopt it only if it decodes, is non-empty, and
    /// isn't a downgrade. Failures (offline, etc.) leave the current catalog intact.
    func refresh() async {
        do {
            var request = URLRequest(url: remoteURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                refreshFailed = true
                return
            }
            let fetched = try JSONDecoder().decode(TicketCatalog.self, from: data)
            refreshFailed = false   // server reachable & valid
            guard !fetched.cities.isEmpty, fetched.version >= catalog.version else { return }
            catalog = fetched
            Self.writeCache(data)
        } catch {
            // Offline or bad response — keep the cached/bundled catalog.
            refreshFailed = true
        }
    }

    // MARK: - Local persistence

    private static var cacheURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("tickets-cache.json")
    }

    private static func writeCache(_ data: Data) {
        guard let url = cacheURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Prefer the disk cache, but defer to the bundled copy if it's newer
    /// (e.g. right after an app update ships a fresher snapshot).
    static func loadCachedOrBundled() -> TicketCatalog {
        let bundled = loadBundled()
        if let url = cacheURL,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(TicketCatalog.self, from: data),
           !cached.cities.isEmpty,
           cached.version >= bundled.version {
            return cached
        }
        return bundled
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
