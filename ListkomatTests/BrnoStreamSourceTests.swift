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

    /// A real message from the CURRENT stream (Kordis_stream), captured
    /// 2026-08-29 — tram line 4 in Brno. Note the integral `Bearing`/`Delay`
    /// (the old fixture had `-1.0`/`4.0`): the feed emits both forms.
    private let tramMessage = """
    {"geometry":{"x":16.62566,"y":49.204418,"spatialReference":{"wkid":4326}},"attributes":\
    {"ID":1837,"IDB":0,"IDC":0,"VType":0,"LType":0,"Lat":49.204418,"Lng":16.62566,\
    "Bearing":45,"LineID":4,"LineName":"4","RouteID":4160,"Course":"00405","LF":"true",\
    "Delay":2,"LastStopID":1676,"FinalStopID":1014,"IsInactive":"false",\
    "TimeUpdated":1788028227359,"globalid":"{E1EA7CF6}"}}
    """

    func testStreamURLTargetsTheYearlessKordisStream() {
        // No annual rollover any more: stream_kordis_26 was still registered but
        // silent on 2026-08-29, and the live feed's name carries no year. A year
        // appearing in this URL again is the regression that broke the map twice.
        XCTAssertEqual(BrnoStreamSource.streamName, "Kordis_stream")
        // The /ags4/rest/... URL printed in the docs does not upgrade to WS;
        // only the /geoevent/ws/... form works, and only with /subscribe (the
        // bare /StreamServer the metadata advertises upgrades but stays silent).
        XCTAssertEqual(
            BrnoStreamSource.currentStreamURL().absoluteString,
            "wss://gis.brno.cz/geoevent/ws/services/Kordis_stream/StreamServer/subscribe")
    }

    func testFirstMessageTimeoutExceedsFeedBatchPeriod() {
        // KORDIS emits the whole fleet in one burst every ~28 s, so a deadline
        // below that fails the fetch on a healthy stream (the "Živá data
        // dočasně nedostupná" toast the 10 s deadline produced).
        XCTAssertGreaterThan(BrnoStreamSource.firstMessageTimeout, 30)
    }

    func testStallBudgetFitsInsideFreshness() {
        // Detecting a silent-but-open socket is only half the job: detection can
        // lag a poll, and the reconnect it triggers then blocks fetch() for the
        // whole first-message deadline before it can throw. The user-visible
        // promise — a toast while the last positions are still fresh, rather
        // than stale markers sitting there unflagged — holds only if the SUM
        // fits inside freshnessLimit. Asserting just `stallTimeout <
        // freshnessLimit` would pass at 90 s and still miss by 16 s.
        let worstCase = BrnoStreamSource.stallTimeout
            + LiveMapViewModel.pollInterval
            + BrnoStreamSource.firstMessageTimeout
        XCTAssertLessThan(worstCase, BrnoVehicleSource.freshnessLimit,
                          "stall recovery must finish before the map's positions age out")
        // ...but above a couple of missed ~28 s bursts, so an ordinary gap in
        // the feed doesn't churn the connection.
        XCTAssertGreaterThan(BrnoStreamSource.stallTimeout, 56)
    }

    func testDecodesCurrentStreamMessage() throws {
        let update = try BrnoStreamDecoder.decode(Data(tramMessage.utf8))
        XCTAssertEqual(update.id, "1837")
        let v = try XCTUnwrap(update.vehicle)
        XCTAssertEqual(v.line, "4")
        XCTAssertEqual(v.kind, .tram)                         // VType 0
        XCTAssertEqual(v.bearing, 45)
        XCTAssertEqual(v.destinationId, 1014)
        XCTAssertEqual(v.delay, 2)
        XCTAssertEqual(v.coordinate.latitude, 49.204418, accuracy: 0.000001)
        XCTAssertEqual(v.coordinate.longitude, 16.62566, accuracy: 0.000001)
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

    func testSnapshotReturnsFreshestFirst() throws {
        // TransitMapView caps markers with prefix(300) — the snapshot must hand
        // back freshest-first (as the old orderByFields=TimeUpdated DESC did),
        // or the cap keeps an arbitrary, flickering subset.
        var snap = BrnoStreamSnapshot()
        for i in 1...20 {   // ID i updated i seconds after the base timestamp
            let msg = busMessage
                .replacingOccurrences(of: "\"ID\":21042", with: "\"ID\":\(i)")
                .replacingOccurrences(of: "\"TimeUpdated\":1786451030883",
                                      with: "\"TimeUpdated\":\(1_786_451_030_883 + i * 1000)")
            snap.apply(try BrnoStreamDecoder.decode(Data(msg.utf8)))
        }
        let now = Date(timeIntervalSince1970: 1_786_451_050.883)
        XCTAssertEqual(snap.vehicles(now: now).map(\.id), (1...20).reversed().map(String.init))
    }

    func testRetainedPositionsOutliveFreshnessButNotThePruneHorizon() throws {
        // #31: these are painted greyed while the first live burst is still in
        // flight, so they must survive the live freshness rule — but not outlast
        // the horizon at which `prune` discards them anyway, or a map reopened
        // the next morning would show last night's fleet.
        var snap = BrnoStreamSnapshot()
        snap.apply(try BrnoStreamDecoder.decode(Data(busMessage.utf8)))
        let sent = Date(timeIntervalSince1970: 1_786_451_030.883)
        let limit = BrnoStreamSource.retainedLimit

        XCTAssertGreaterThan(limit, BrnoVehicleSource.freshnessLimit,
                             "retained positions exist precisely to outlive the live freshness rule")
        XCTAssertEqual(snap.vehicles(now: sent.addingTimeInterval(300), fresherThan: limit).count, 1,
                       "five minutes old is still worth showing greyed")
        XCTAssertTrue(snap.vehicles(now: sent.addingTimeInterval(limit + 1), fresherThan: limit).isEmpty)
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
