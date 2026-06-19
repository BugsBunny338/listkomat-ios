import XCTest
@testable import Listkomat

final class StopsStoreTests: XCTestCase {
    func testDecodesStops() throws {
        let json = """
        [{"id":"a","name":"Mendlovo náměstí","lat":49.19,"lng":16.59}]
        """
        let stops = try StopsStore.decode(Data(json.utf8))
        XCTAssertEqual(stops.count, 1)
        let s = try XCTUnwrap(stops.first)
        XCTAssertEqual(s.name, "Mendlovo náměstí")
        XCTAssertEqual(s.coordinate.latitude, 49.19, accuracy: 0.0001)
        XCTAssertEqual(s.coordinate.longitude, 16.59, accuracy: 0.0001)
    }
}
