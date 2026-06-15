import XCTest
import CoreLocation
@testable import Listkomat

final class NearestCityTests: XCTestCase {
    private let cities = [
        City(key: "praha", name: "Praha", lat: 50.075538, lng: 14.437800, smsNumber: "90206", tickets: []),
        City(key: "brno", name: "Brno", lat: 49.195060, lng: 16.606837, smsNumber: "90206", tickets: []),
        City(key: "ostrava", name: "Ostrava", lat: 49.820923, lng: 18.262524, smsNumber: "90206", tickets: [])
    ]

    func testPicksClosestCity() {
        let nearBrno = CLLocationCoordinate2D(latitude: 49.20, longitude: 16.60)
        XCTAssertEqual(LocationManager.nearestCity(to: nearBrno, in: cities)?.key, "brno")

        let nearPraha = CLLocationCoordinate2D(latitude: 50.08, longitude: 14.44)
        XCTAssertEqual(LocationManager.nearestCity(to: nearPraha, in: cities)?.key, "praha")
    }

    func testEmptyCitiesReturnsNil() {
        let here = CLLocationCoordinate2D(latitude: 50, longitude: 14)
        XCTAssertNil(LocationManager.nearestCity(to: here, in: []))
    }

    func testFarLocationExceedsDefaultThreshold() {
        // Salt Lake City — thousands of km from any CZ city, so we must NOT auto-default.
        let saltLakeCity = CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910)
        let result = LocationManager.nearest(to: saltLakeCity, in: cities)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!.distanceKm, LocationManager.maxDefaultDistanceKm)
    }

    func testInCityIsWithinThreshold() {
        let inBrno = CLLocationCoordinate2D(latitude: 49.195, longitude: 16.606)
        let result = LocationManager.nearest(to: inBrno, in: cities)
        XCTAssertEqual(result?.city.key, "brno")
        XCTAssertLessThan(result!.distanceKm, LocationManager.maxDefaultDistanceKm)
    }
}
