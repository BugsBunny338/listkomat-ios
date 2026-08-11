import XCTest
import CoreLocation
@testable import Listkomat

final class VehicleModelTests: XCTestCase {
    func testMetroKind() {
        XCTAssertEqual(VehicleKind.allCases.count, 5)
        // Locale-independent by design — the Brno easter egg stays "Šalina" in
        // every language. English vehicle names are pinned in LocalizationTests.
        XCTAssertEqual(VehicleKind.tram.displayName(brno: true), "Šalina")
    }

    func testDestinationNameCarried() {
        let v = Vehicle(id: "x", coordinate: .init(latitude: 50, longitude: 14),
                        bearing: nil, line: "A", kind: .metro,
                        updatedAt: Date(), destinationId: nil, destinationName: "Motol")
        XCTAssertEqual(v.destinationName, "Motol")
        XCTAssertNil(v.destinationId)
    }
}
