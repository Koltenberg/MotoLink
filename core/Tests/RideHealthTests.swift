import Foundation
import XCTest
@testable import MotoLinkCore

final class RideHealthTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)

    func testCachedFixBeforeRideIsRetainedOnlyAsRawObservation() {
        XCTAssertFalse(GPSContinuity.acceptsTimestamp(start.addingTimeInterval(-10),
            startedAt: start, previous: nil, now: start.addingTimeInterval(2)))
        XCTAssertTrue(GPSContinuity.acceptsTimestamp(start,
            startedAt: start, previous: nil, now: start.addingTimeInterval(2)))
    }

    func testStaleAndOutOfOrderFixesDoNotAdvanceRoute() {
        XCTAssertFalse(GPSContinuity.acceptsTimestamp(start,
            startedAt: start, previous: nil, now: start.addingTimeInterval(30)))
        XCTAssertFalse(GPSContinuity.acceptsTimestamp(start.addingTimeInterval(5),
            startedAt: start, previous: start.addingTimeInterval(5), now: start.addingTimeInterval(6)))
        XCTAssertTrue(GPSContinuity.acceptsTimestamp(start.addingTimeInterval(6),
            startedAt: start, previous: start.addingTimeInterval(5), now: start.addingTimeInterval(7)))
    }

    func testBLEConnectionAloneIsNotLiveTelemetry() {
        XCTAssertEqual(TelemetryFreshness.state(connected: true, ready: true,
            lastStreamAt: nil, now: start), .waiting)
        XCTAssertEqual(TelemetryFreshness.state(connected: false, ready: false,
            lastStreamAt: start, now: start), .disconnected)
        XCTAssertEqual(TelemetryFreshness.state(connected: true, ready: false,
            lastStreamAt: start, now: start), .waiting)
    }

    func testSilentStreamBecomesStaleAndRecoversWithNewData() {
        XCTAssertEqual(TelemetryFreshness.state(connected: true, ready: true,
            lastStreamAt: start, now: start.addingTimeInterval(15)), .receiving)
        XCTAssertEqual(TelemetryFreshness.state(connected: true, ready: true,
            lastStreamAt: start, now: start.addingTimeInterval(16)), .stale)
        XCTAssertEqual(TelemetryFreshness.state(connected: true, ready: true,
            lastStreamAt: start.addingTimeInterval(30), now: start.addingTimeInterval(30)), .receiving)
    }
}
