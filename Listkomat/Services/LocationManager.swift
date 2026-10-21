import Foundation
import CoreLocation

/// Finds the nearest known city to auto-pick it — but only if the user is
/// plausibly *in* Czechia. Beyond `maxDefaultDistanceKm` we don't guess.
///
/// One fix per return to the app (`requestFix()`), never continuous updates:
/// the city may change only when the user comes back, not mid-use (a Praha →
/// Brno train used to flip the list halfway). Rules in `CitySelection`.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    nonisolated static let maxDefaultDistanceKm = CitySelection.maxDefaultDistanceKm
    /// Give up on a fix after this long; the fallback (or the picker) covers it.
    static let fixTimeout: TimeInterval = 30

    @Published var nearestCityKey: String?
    @Published var nearestDistanceKm: Double?
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    /// From `requestFix()` until a usable fix, an error or the timeout ends it.
    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    private let cities: [City]
    private var timeout: Task<Void, Never>?

    init(cities: [City]) {
        self.cities = cities
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// What GPS knows now. A fix from earlier in this process stays while a new
    /// one comes in, rather than flashing the searching state.
    var state: LocationState {
        if isDenied { return .denied }
        if let key = nearestCityKey, let km = nearestDistanceKm { return .located(cityKey: key, distanceKm: km) }
        return isLocating ? .searching : .idle
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Take one fix: updates stop after the first usable one.
    func requestFix() {
        guard isAuthorized, !isLocating else { return }
        isLocating = true
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.fixTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishFix()
        }
    }

    private func finishFix() {
        manager.stopUpdatingLocation()
        timeout?.cancel()
        isLocating = false
    }

    /// True once we have a fix but the nearest supported city is too far to default to.
    var isFarFromAllCities: Bool {
        guard let dist = nearestDistanceKm else { return false }
        return dist > Self.maxDefaultDistanceKm
    }

    /// Pure, testable: nearest city + its distance in km.
    nonisolated static func nearest(to coordinate: CLLocationCoordinate2D, in cities: [City]) -> (city: City, distanceKm: Double)? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var best: (City, Double)?
        for city in cities {
            let km = here.distance(from: CLLocation(latitude: city.lat, longitude: city.lng)) / 1000.0
            if best == nil || km < best!.1 { best = (city, km) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Convenience kept for tests / callers that only need the city.
    nonisolated static func nearestCity(to coordinate: CLLocationCoordinate2D, in cities: [City]) -> City? {
        nearest(to: coordinate, in: cities)?.city
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CoreLocation may hand out a cached fix first; one older than
        // `CitySelection.fixMaxAge` could be from another city.
        guard let location = locations.last(where: {
            $0.horizontalAccuracy >= 0 && CitySelection.fixIsFresh(age: -$0.timestamp.timeIntervalSinceNow)
        }) else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            guard self.isLocating else { return }   // a straggler after the fix: ignore until the next return
            if let result = Self.nearest(to: coordinate, in: self.cities) {
                self.nearestCityKey = result.city.key
                self.nearestDistanceKm = result.distanceKm
            }
            self.finishFix()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `locationUnknown` is transient: CoreLocation keeps trying.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in self.finishFix() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
