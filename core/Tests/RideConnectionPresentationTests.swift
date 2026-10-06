import Foundation
import XCTest
@testable import MotoLinkCore

final class RideConnectionPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testTransportConnectionWithoutFramesDoesNotClaimLiveData() {
        XCTAssertEqual(RideConnectionPresentation.state(powered: true, connected: true,
            connecting: false, lastStreamAt: nil, now: now), .waitingForData)
    }

    func testFreshnessExpiresWithoutAnotherBluetoothCallback() {
        XCTAssertEqual(RideConnectionPresentation.state(powered: true, connected: true,
            connecting: false, lastStreamAt: now, now: now.addingTimeInterval(3)), .receiving)
        XCTAssertEqual(RideConnectionPresentation.state(powered: true, connected: true,
            connecting: false, lastStreamAt: now, now: now.addingTimeInterval(3.01)), .stale)
    }

    func testDisconnectedLinkCannotReuseLastSessionsFreshFrame() {
        XCTAssertEqual(RideConnectionPresentation.state(powered: true, connected: false,
            connecting: true, lastStreamAt: now, now: now), .connecting)
        XCTAssertEqual(RideConnectionPresentation.state(powered: true, connected: false,
            connecting: false, lastStreamAt: now, now: now), .disconnected)
    }

    func testPoweredOffAndClockRollbackCannotShowGreen() {
        XCTAssertEqual(RideConnectionPresentation.state(powered: false, connected: true,
            connecting: false, lastStreamAt: now, now: now), .unavailable)
        XCTAssertEqual(RideConnectionPresentation.state(powered: true, connected: true,
            connecting: false, lastStreamAt: now.addingTimeInterval(1), now: now), .waitingForData)
    }
}
