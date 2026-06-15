import XCTest
@testable import Listkomat

final class CatalogTests: XCTestCase {
    func testDecodesCatalog() throws {
        let json = """
        {
          "version": 1,
          "updatedAt": "2026-06-15",
          "cities": [
            {
              "key": "praha", "name": "Praha", "lat": 50.07, "lng": 14.43, "smsNumber": "90206",
              "tickets": [
                { "code": "DPT42", "duration": "30 min", "durationMinutes": 30, "priceKc": 42 },
                { "code": "DPT350", "duration": "72 h", "durationMinutes": 4320, "priceKc": 350, "note": "demo" }
              ]
            }
          ]
        }
        """
        let catalog = try JSONDecoder().decode(TicketCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.cities.count, 1)

        let city = try XCTUnwrap(catalog.cities.first)
        XCTAssertEqual(city.smsNumber, "90206")
        XCTAssertEqual(city.tickets.count, 2)

        let first = try XCTUnwrap(city.tickets.first)
        XCTAssertEqual(first.code, "DPT42")
        XCTAssertEqual(first.durationMinutes, 30)
        XCTAssertNil(first.note)               // optional note absent -> nil

        let last = try XCTUnwrap(city.tickets.last)
        XCTAssertEqual(last.note, "demo")      // optional note present
    }
}
