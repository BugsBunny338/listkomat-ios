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

    // Guards the *bundled* file, which the fixture above never touches: five
    // stations named "(-)" shipped in v2.1 as pins the user cannot identify (#9).
    // `StopsStore.bundled` reads Bundle.main, which is the test runner here, so
    // the app bundle is located the way LocalizationTests does it.
    func testBundledPragueStopsCarryNoPlaceholderNames() throws {
        let appBundle = Bundle(for: CatalogStore.self)
        let url = try XCTUnwrap(appBundle.url(forResource: "prague-stops", withExtension: "json"))
        let stops = try StopsStore.decode(Data(contentsOf: url))

        // Non-trivial count first — decode failure would otherwise pass vacuously.
        XCTAssertGreaterThan(stops.count, 9_000)
        let placeholders = stops.filter { !$0.name.contains { $0.isLetter || $0.isNumber } }
        XCTAssertEqual(placeholders.map(\.name), [], "placeholder-named stops must not ship")
    }
}
