import XCTest
import CoreLocation
@testable import Listkomat

final class BrnoStreamSourceTests: XCTestCase {
    // A real message captured from the live stream 2026-08-11 (globalid trimmed).
    // Bearing -1 = unknown; VType 4 = regional bus (semantics unchanged from the
    // old FeatureServer feed — verified against 400 live messages).
    private let busMessage = """
    {"geometry":{"x":16.309654,"y":49.048447,"spatialReference":{"wkid":4326}},"attributes":\
    {"ID":21042,"IDB":0,"IDC":0,"VType":4,"LType":4,"Lat":49.048447,"Lng":16.309654,\
    "Bearing":-1.0,"LineID":164,"LineName":"164","RouteID":58,"Course":"16402","LF":"true",\
    "Delay":4.0,"LastStopID":14499,"FinalStopID":15317,"IsInactive":"false",\
    "TimeUpdated":1786451030883,"globalid":"{8C5B80BD}"}}
    """

    func testStreamURLRollsOverByYear() {
        XCTAssertEqual(BrnoStreamSource.streamName(year: 2026), "stream_kordis_26")
        XCTAssertEqual(BrnoStreamSource.streamName(year: 2027), "stream_kordis_27")
        // The /ags4/rest/... URL printed in the docs does not upgrade to WS;
        // only the /geoevent/ws/... form works.
        XCTAssertEqual(
            BrnoStreamSource.currentStreamURL(now: Date(timeIntervalSince1970: 1_786_451_030)).absoluteString,
            "wss://gis.brno.cz/geoevent/ws/services/stream_kordis_26/StreamServer/subscribe")
    }

    func testDecodesSingleUpdateMessage() throws {
        let update = try BrnoStreamDecoder.decode(Data(busMessage.utf8))
        XCTAssertEqual(update.id, "21042")
        let v = try XCTUnwrap(update.vehicle)
        XCTAssertEqual(v.line, "164")
        XCTAssertEqual(v.kind, .bus)                          // VType 4
        XCTAssertNil(v.bearing)                               // -1 -> nil
        XCTAssertEqual(v.destinationId, 15317)
        XCTAssertEqual(v.delay, 4.0)
        XCTAssertEqual(v.coordinate.latitude, 49.048447, accuracy: 0.000001)
        XCTAssertEqual(v.coordinate.longitude, 16.309654, accuracy: 0.000001)
        XCTAssertEqual(v.updatedAt.timeIntervalSince1970, 1_786_451_030.883, accuracy: 0.001)
    }

    func testInactiveMessageYieldsRemoval() throws {
        let inactive = busMessage.replacingOccurrences(of: "\"IsInactive\":\"false\"",
                                                       with: "\"IsInactive\":\"true\"")
        let update = try BrnoStreamDecoder.decode(Data(inactive.utf8))
        XCTAssertEqual(update.id, "21042")
        XCTAssertNil(update.vehicle)
    }

    func testOutOfAreaMessageYieldsRemoval() throws {
        // Vehicle left the Brno bounding box (Prague coordinates) -> treat as removal.
        let faraway = busMessage
            .replacingOccurrences(of: "\"x\":16.309654,\"y\":49.048447", with: "\"x\":14.4378,\"y\":50.0755")
        let update = try BrnoStreamDecoder.decode(Data(faraway.utf8), bbox: .brnoArea)
        XCTAssertEqual(update.id, "21042")
        XCTAssertNil(update.vehicle)

        // Without a bbox the same message is a normal update.
        XCTAssertNotNil(try BrnoStreamDecoder.decode(Data(faraway.utf8), bbox: nil).vehicle)
    }

    func testSnapshotKeepsLatestPositionPerVehicleAndRemoves() throws {
        var snap = BrnoStreamSnapshot()
        let now = Date(timeIntervalSince1970: 1_786_451_030.883)

        snap.apply(try BrnoStreamDecoder.decode(Data(busMessage.utf8)))
        XCTAssertEqual(snap.vehicles(now: now).map(\.id), ["21042"])

        // A newer message for the same vehicle replaces its position.
        let moved = busMessage.replacingOccurrences(of: "\"Bearing\":-1.0", with: "\"Bearing\":90.0")
        snap.apply(try BrnoStreamDecoder.decode(Data(moved.utf8)))
        let vehicles = snap.vehicles(now: now)
        XCTAssertEqual(vehicles.count, 1)
        XCTAssertEqual(vehicles.first?.bearing, 90.0)

        // A removal update drops the vehicle.
        let inactive = busMessage.replacingOccurrences(of: "\"IsInactive\":\"false\"",
                                                       with: "\"IsInactive\":\"true\"")
        snap.apply(try BrnoStreamDecoder.decode(Data(inactive.utf8)))
        XCTAssertTrue(snap.vehicles(now: now).isEmpty)
    }

    func testSnapshotDropsStaleVehiclesAtReadTime() throws {
        var snap = BrnoStreamSnapshot()
        snap.apply(try BrnoStreamDecoder.decode(Data(busMessage.utf8)))

        let sent = Date(timeIntervalSince1970: 1_786_451_030.883)
        XCTAssertEqual(snap.vehicles(now: sent.addingTimeInterval(60)).count, 1)   // still fresh
        XCTAssertTrue(snap.vehicles(now: sent.addingTimeInterval(600)).isEmpty)    // aged out
    }

    func testSnapshotPruneEvictsAgedEntries() throws {
        var snap = BrnoStreamSnapshot()
        snap.apply(try BrnoStreamDecoder.decode(Data(busMessage.utf8)))

        let sent = Date(timeIntervalSince1970: 1_786_451_030.883)
        snap.prune(now: sent.addingTimeInterval(60))
        XCTAssertEqual(snap.storedCount, 1)                    // fresh entry kept

        snap.prune(now: sent.addingTimeInterval(3600))
        XCTAssertEqual(snap.storedCount, 0)                    // stale entry evicted
    }
}
