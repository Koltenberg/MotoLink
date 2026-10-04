import Foundation
import XCTest
@testable import MotoLinkCore

final class SignalComparisonPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let session = UUID()

    private func reading(_ dBm: Int, secondsAgo: TimeInterval, sessionID: UUID? = nil) -> SignalComparisonPolicy.Reading {
        .init(dBm: dBm, measuredAt: now.addingTimeInterval(-secondsAgo), sessionID: sessionID ?? session)
    }

    func testCompleteRecentABAUsesMediansOfBothDashVisits() {
        let first = [reading(-85, secondsAgo: 55), reading(-83, secondsAgo: 50)]
        let seat = [reading(-72, secondsAgo: 40), reading(-70, secondsAgo: 35)]
        let returning = [reading(-84, secondsAgo: 20), reading(-82, secondsAgo: 15)]

        let result = SignalComparisonPolicy.summary(firstDash: first, seat: seat, returnDash: returning,
                                                    at: now, sessionID: session, connected: true)
        XCTAssertEqual(result?.dashMedianDBm, -83.5)
        XCTAssertEqual(result?.seatMedianDBm, -71)
        XCTAssertEqual(result?.seatImprovementDB, 12.5)
    }

    func testStaleSeatSamplesCannotProduceAComparison() {
        let first = [reading(-85, secondsAgo: 380), reading(-84, secondsAgo: 375)]
        let seat = [reading(-71, secondsAgo: 360), reading(-72, secondsAgo: 355)]
        let returning = [reading(-84, secondsAgo: 10), reading(-83, secondsAgo: 5)]
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: seat, returnDash: returning,
                                                    at: now, sessionID: session, connected: true))
        XCTAssertFalse(SignalComparisonPolicy.hasEnoughRecentReadings(seat, at: now, sessionID: session))
    }

    func testEachPhaseNeedsTwoRecentSamplesAndAnActiveConnection() {
        let first = [reading(-85, secondsAgo: 60), reading(-84, secondsAgo: 55)]
        let seat = [reading(-72, secondsAgo: 40), reading(-71, secondsAgo: 35)]
        let returning = [reading(-84, secondsAgo: 20), reading(-83, secondsAgo: 15)]
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: [seat[0]], returnDash: returning,
                                                    at: now, sessionID: session, connected: true))
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: seat, returnDash: [],
                                                    at: now, sessionID: session, connected: true))
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: seat, returnDash: [returning[0]],
                                                    at: now, sessionID: session, connected: true))
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: seat, returnDash: returning,
                                                    at: now, sessionID: session, connected: false))
    }

    func testCrossSessionAndOutOfOrderReadingsAreRejected() {
        let first = [reading(-85, secondsAgo: 60), reading(-84, secondsAgo: 55)]
        let seat = [reading(-72, secondsAgo: 40), reading(-71, secondsAgo: 35)]
        let returning = [reading(-84, secondsAgo: 20), reading(-83, secondsAgo: 15)]
        let otherSessionSeat = [seat[0], reading(-71, secondsAgo: 35, sessionID: UUID())]
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: otherSessionSeat,
                                                    returnDash: returning, at: now, sessionID: session,
                                                    connected: true))
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: seat, seat: first,
                                                    returnDash: returning, at: now, sessionID: session,
                                                    connected: true))
    }

    func testTwoMinuteBoundaryAndFutureReadings() {
        let boundary = reading(-84, secondsAgo: 120)
        XCTAssertTrue(SignalComparisonPolicy.isRecent(boundary, at: now, sessionID: session))
        XCTAssertFalse(SignalComparisonPolicy.isRecent(reading(-84, secondsAgo: 120.01),
                                                       at: now, sessionID: session))
        XCTAssertFalse(SignalComparisonPolicy.isRecent(reading(-84, secondsAgo: -1),
                                                       at: now, sessionID: session))
    }

    func testUnavailableRSSISentinelNeverCountsAsASample() {
        let first = [reading(-85, secondsAgo: 60), reading(-84, secondsAgo: 55)]
        let seat = [reading(-72, secondsAgo: 40), reading(127, secondsAgo: 35)]
        let returning = [reading(-84, secondsAgo: 20), reading(-83, secondsAgo: 15)]
        XCTAssertFalse(SignalComparisonPolicy.isValidRSSI(127))
        XCTAssertFalse(SignalComparisonPolicy.isValidRSSI(0))
        XCTAssertFalse(SignalComparisonPolicy.isValidRSSI(-128))
        XCTAssertFalse(SignalComparisonPolicy.hasEnoughRecentReadings(seat, at: now, sessionID: session))
        XCTAssertNil(SignalComparisonPolicy.summary(firstDash: first, seat: seat, returnDash: returning,
                                                    at: now, sessionID: session, connected: true))

        let validSeat = [seat[0], reading(-70, secondsAgo: 34), seat[1]]
        let result = SignalComparisonPolicy.summary(firstDash: first, seat: validSeat,
                                                    returnDash: returning, at: now,
                                                    sessionID: session, connected: true)
        XCTAssertEqual(result?.seatMedianDBm, -71)
    }
}
