import Foundation
import XCTest
@testable import MotoLinkCore

final class RideLiveActivityStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func state(connected: Bool = true, streamAge: Double? = 0,
                       paused: Bool = false, speed: Double? = 42, speedAge: Double = 0) -> RideLiveActivityState {
        RideLiveActivityState.snapshot(name: "Takihiro", connected: connected,
            lastStreamAt: streamAge.map { now.addingTimeInterval(-$0) }, recording: true,
            paused: paused, elapsed: 2_400, distance: 15_200, speed: speed,
            speedAt: now.addingTimeInterval(-speedAge), now: now)
    }

    func testFreshStreamShowsBikeSpeedAndProgressWithoutCoordinates() throws {
        let value = state()
        XCTAssertEqual(value.connection, .live)
        XCTAssertEqual(value.speedKmh, 42)
        XCTAssertEqual(value.durationText, "40:00")
        XCTAssertEqual(value.distanceMeters, 15_200)
        XCTAssertEqual(value.staleDate, now.addingTimeInterval(10))
        XCTAssertEqual(try JSONDecoder().decode(RideLiveActivityState.self, from: JSONEncoder().encode(value)), value)
    }

    func testConnectedIconWithoutFreshStreamNeverShowsOldSpeed() {
        XCTAssertEqual(state(streamAge: nil).connection, .waiting)
        XCTAssertNil(state(streamAge: nil).speedKmh)
        XCTAssertNil(state(streamAge: 11).speedKmh)
        XCTAssertNil(state(streamAge: -1).speedKmh)
        XCTAssertNil(state(speedAge: 11).speedKmh)
        XCTAssertNil(state(speedAge: -1).speedKmh)
        XCTAssertNil(state(speed: .nan).speedKmh)
        XCTAssertNil(state(speed: 361).speedKmh)
        // Re-publishing a nine-second-old speed cannot give it ten more
        // seconds of apparent freshness on the lock screen.
        XCTAssertEqual(state(streamAge: 9, speedAge: 9).staleDate, now.addingTimeInterval(1))
    }

    func testDisconnectAndPauseNeverPretendTheBikeIsConnected() {
        XCTAssertEqual(state(connected: false).connection, .disconnected)
        XCTAssertNil(state(connected: false).speedKmh)
        XCTAssertEqual(state(paused: true).connection, .paused)
        XCTAssertNil(state(paused: true).speedKmh)
        XCTAssertEqual(state().statusText(stale: true), "Открой Moto Link для обновления")
    }

    func testPreferenceAndDismissalWinOverConnectionAndRecording() {
        XCTAssertFalse(RideLiveActivityState.shouldDisplay(enabled: false, connected: true, recording: true,
            hasActivity: true, dismissed: false))
        XCTAssertFalse(RideLiveActivityState.shouldDisplay(enabled: true, connected: true, recording: true,
            hasActivity: false, dismissed: true))
        XCTAssertTrue(RideLiveActivityState.shouldDisplay(enabled: true, connected: true, recording: false,
            hasActivity: false, dismissed: false))
    }

    func testRecordingCanKeepExistingCardThroughPauseButCannotStartCardWithoutBike() {
        XCTAssertTrue(RideLiveActivityState.shouldDisplay(enabled: true, connected: false, recording: true,
            hasActivity: true, dismissed: false))
        XCTAssertFalse(RideLiveActivityState.shouldDisplay(enabled: true, connected: false, recording: true,
            hasActivity: false, dismissed: false))
        XCTAssertFalse(RideLiveActivityState.shouldDisplay(enabled: true, connected: false, recording: false,
            hasActivity: true, dismissed: false))
    }

    func testMalformedValuesCannotOverflowOrLeakIntoTheCard() {
        let value = RideLiveActivityState.snapshot(name: " \n ", connected: false, lastStreamAt: nil,
            recording: false, paused: false, elapsed: .infinity, distance: .nan,
            speed: .infinity, speedAt: now, now: now)
        XCTAssertEqual(value.motorcycleName, "Мой мотоцикл")
        XCTAssertEqual(value.elapsedSeconds, 0)
        XCTAssertEqual(value.distanceMeters, 0)
        XCTAssertNil(value.speedKmh)
    }
}
