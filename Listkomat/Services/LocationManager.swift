import Foundation
import CoreLocation

/// Tracks coarse location to auto-pick the nearest known city. Manual override
/// always wins in the UI; this just provides a sensible default.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published var nearestCityKey: String?
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    @Published var hasFix = false

    private let manager = CLLocationManager()
    private let cities: [City]

    init(cities: [City]) {
        self.cities = cities
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestAndStart() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// Pure, testable: nearest city to a coordinate by great-circle distance.
    nonisolated static func nearestCity(to coordinate: CLLocationCoordinate2D, in cities: [City]) -> City? {
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return cities.min { a, b in
            here.distance(from: CLLocation(latitude: a.lat, longitude: a.lng))
                < here.distance(from: CLLocation(latitude: b.lat, longitude: b.lng))
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        Task { @MainActor in
            self.hasFix = true
            self.nearestCityKey = Self.nearestCity(to: coordinate, in: self.cities)?.key
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }
}
