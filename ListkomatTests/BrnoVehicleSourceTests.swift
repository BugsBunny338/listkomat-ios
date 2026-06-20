import XCTest
import CoreLocation
@testable import Listkomat

final class BrnoVehicleSourceTests: XCTestCase {
    // Two real features (trimmed). First is a tram (VType 0) but inactive;
    // second is an active bus (VType 4) with a known bearing.
    private let fixture = """
    {"type":"FeatureCollection","features":[
      {"geometry":{"type":"Point","coordinates":[16.6371,49.2142]},"properties":
        {"LineName":"1","Bearing":-1,"TimeUpdated":1767776798912,"IsInactive":"true","VType":0,"ID":7098}},
      {"geometry":{"type":"Point","coordinates":[16.6012,49.4798]},"properties":
        {"LineName":"258","Bearing":225,"TimeUpdated":1767776798912,"IsInactive":"false","VType":4,"ID":21856,"FinalStopID":12515}}
    ]}
    """

    func testDecodesAndDropsInactive() throws {
        let all = try BrnoVehicleSource.decode(Data(fixture.utf8))
        XCTAssertEqual(all.count, 1)                 // inactive tram dropped
        let v = try XCTUnwrap(all.first)
        XCTAssertEqual(v.id, "21856")
        XCTAssertEqual(v.line, "258")
        XCTAssertEqual(v.kind, .bus)
        XCTAssertEqual(v.bearing, 225)
        XCTAssertEqual(v.destinationId, 12515)
        XCTAssertEqual(v.coordinate.latitude, 49.4798, accuracy: 0.0001)
        XCTAssertEqual(v.coordinate.longitude, 16.6012, accuracy: 0.0001)
    }

    func testStopNamesDecode() throws {
        let map = try StopNamesStore.decode(Data(#"{"1286":"Královo Pole, nádraží","12515":"Obora"}"#.utf8))
        XCTAssertEqual(map[12515], "Obora")
        XCTAssertEqual(map[1286], "Královo Pole, nádraží")
    }

    func testBearingMinusOneBecomesNilAndTramKind() throws {
        let active = fixture.replacingOccurrences(of: "\"true\"", with: "\"false\"")
        let all = try BrnoVehicleSource.decode(Data(active.utf8))
        let tram = try XCTUnwrap(all.first(where: { $0.id == "7098" }))
        XCTAssertNil(tram.bearing)                   // -1 -> nil
        XCTAssertEqual(tram.kind, .tram)             // VType 0
    }

    func testVTypeMapping() {
        XCTAssertEqual(BrnoVehicleSource.kind(forVType: 0), .tram)
        XCTAssertEqual(BrnoVehicleSource.kind(forVType: 1), .trolleybus)
        XCTAssertEqual(BrnoVehicleSource.kind(forVType: 2), .bus)
        XCTAssertEqual(BrnoVehicleSource.kind(forVType: 4), .bus)
        XCTAssertEqual(BrnoVehicleSource.kind(forVType: 5), .train)
    }

    func testDecodeDropsFeaturesOutsideBoundingBox() throws {
        let withFaraway = """
        {"type":"FeatureCollection","features":[
          {"geometry":{"type":"Point","coordinates":[16.6012,49.4798]},"properties":
            {"LineName":"258","Bearing":225,"TimeUpdated":1767776798912,"IsInactive":"false","VType":4,"ID":21856}},
          {"geometry":{"type":"Point","coordinates":[14.4378,50.0755]},"properties":
            {"LineName":"22","Bearing":10,"TimeUpdated":1767776798912,"IsInactive":"false","VType":0,"ID":99999}}
        ]}
        """
        let bounded = try BrnoVehicleSource.decode(Data(withFaraway.utf8), bbox: .brnoArea)
        XCTAssertEqual(bounded.map(\.id), ["21856"])           // Prague tram dropped

        let unbounded = try BrnoVehicleSource.decode(Data(withFaraway.utf8))
        XCTAssertEqual(unbounded.count, 2)                     // no bbox → keep both
    }

    func testBrnoAreaContainsCityCenter() {
        XCTAssertTrue(BrnoVehicleSource.BoundingBox.brnoArea.contains(lat: 49.195, lng: 16.607))
        XCTAssertFalse(BrnoVehicleSource.BoundingBox.brnoArea.contains(lat: 50.075, lng: 14.437))
    }

    func testQueryURLRequestsOnlyNeededFieldsNotStar() {
        let url = BrnoVehicleSource.currentQueryURL().absoluteString
        XCTAssertFalse(url.contains("outFields=*"), "should not request all fields")
        for field in ["ID", "Bearing", "LineName", "VType", "IsInactive", "TimeUpdated", "FinalStopID"] {
            XCTAssertTrue(url.contains(field), "missing required field \(field)")
        }
    }

    func testLayerNameRollsOverByYear() {
        XCTAssertEqual(BrnoVehicleSource.layerName(year: 2026), "Kordis_26_polohy")
        XCTAssertEqual(BrnoVehicleSource.layerName(year: 2027), "Kordis_27_polohy")
    }
}
