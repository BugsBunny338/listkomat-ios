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
              "key": "olomouc", "name": "Olomouc", "lat": 49.59, "lng": 17.25, "smsNumber": "90206",
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
        XCTAssertFalse(city.showsLiveMap)      // absent flag, non-map city -> false
    }

    func testPragueShowsLiveMapClientSide() throws {
        // Prague's live map ships in the binary (PragueVehicleSource), so it's
        // enabled client-side even when the catalog flag is absent — while older
        // App Store builds, which lack that source, stay dark because the catalog
        // flag stays unset. See City.showsLiveMap.
        let json = #"""
        {"version":1,"updatedAt":"2026-07-15","cities":[
          {"key":"praha","name":"Praha","lat":50.07,"lng":14.43,"smsNumber":"90206","tickets":[]}
        ]}
        """#
        let city = try XCTUnwrap(try JSONDecoder()
            .decode(TicketCatalog.self, from: Data(json.utf8)).cities.first)
        XCTAssertNil(city.hasLiveMap)      // catalog flag intentionally unset
        XCTAssertTrue(city.showsLiveMap)   // ...but the client enables Prague itself
    }

    // Prague is enabled by the binary, so `hasLiveMap` cannot switch it off again.
    // `liveMapDisabled` is the remote kill switch for when the proxy or the
    // Golemio key dies — and it works for catalog-gated cities too.
    func testLiveMapDisabledOverridesBothGates() throws {
        let json = #"""
        {"version":1,"updatedAt":"2026-08-11","cities":[
          {"key":"praha","name":"Praha","lat":50.07,"lng":14.43,"smsNumber":"90206",
           "liveMapDisabled":true,"tickets":[]},
          {"key":"brno","name":"Brno","lat":49.19,"lng":16.6,"smsNumber":"90206",
           "hasLiveMap":true,"liveMapDisabled":true,"tickets":[]}
        ]}
        """#
        let cities = try JSONDecoder()
            .decode(TicketCatalog.self, from: Data(json.utf8)).cities
        XCTAssertEqual(cities.count, 2)
        for city in cities {
            XCTAssertFalse(city.showsLiveMap, "\(city.key) should be remotely disabled")
        }
    }

    func testLiveMapDisabledFalseKeepsTheMap() throws {
        let json = #"""
        {"version":1,"updatedAt":"2026-08-11","cities":[
          {"key":"praha","name":"Praha","lat":50.07,"lng":14.43,"smsNumber":"90206",
           "liveMapDisabled":false,"tickets":[]}
        ]}
        """#
        let city = try XCTUnwrap(try JSONDecoder()
            .decode(TicketCatalog.self, from: Data(json.utf8)).cities.first)
        XCTAssertTrue(city.showsLiveMap)
    }

    func testHasLiveMapDecodes() throws {
        let json = """
        {
          "version": 1, "updatedAt": "2026-06-19",
          "cities": [
            { "key": "brno", "name": "Brno", "lat": 49.19, "lng": 16.6, "smsNumber": "90206",
              "hasLiveMap": true, "tickets": [] }
          ]
        }
        """
        let catalog = try JSONDecoder().decode(TicketCatalog.self, from: Data(json.utf8))
        XCTAssertTrue(try XCTUnwrap(catalog.cities.first).showsLiveMap)
    }
}
