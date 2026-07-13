import XCTest
import CoreLocation
@testable import Listkomat

final class VehicleModelTests: XCTestCase {
    func testMetroKind() {
        XCTAssertEqual(VehicleKind.metro.czechName, "Metro")
        XCTAssertEqual(VehicleKind.allCases.count, 5)
    }

    func testDestinationNameCarried() {
        let v = Vehicle(id: "x", coordinate: .init(latitude: 50, longitude: 14),
                        bearing: nil, line: "A", kind: .metro,
                        updatedAt: Date(), destinationId: nil, destinationName: "Motol")
        XCTAssertEqual(v.destinationName, "Motol")
        XCTAssertNil(v.destinationId)
    }
}
