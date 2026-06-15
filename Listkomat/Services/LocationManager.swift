import Foundation
import CoreLocation

/// Tracks coarse location to auto-pick the nearest known city — but only if the
/// user is plausibly *in* Czechia. Beyond `maxDefaultDistanceKm` we don't guess.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    /// Don't auto-select a city if the nearest one is farther than this. Anywhere
    /// in CZ is within ~100 km of a supported city; abroad is obviously not.
    static let maxDefaultDistanceKm = 100.0

    @Published var nearestCityKey: String?
    @Published var nearestDistanceKm: Double?
    @Published var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let cities: [City]

    init(cities: [City]) {
        self.cities = cities
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authorization = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
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
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            if let result = Self.nearest(to: coordinate, in: self.cities) {
                self.nearestCityKey = result.city.key
                self.nearestDistanceKm = result.distanceKm
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
