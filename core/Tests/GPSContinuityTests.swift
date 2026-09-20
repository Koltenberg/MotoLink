import Foundation
import XCTest
@testable import MotoLinkCore

final class GPSContinuityTests: XCTestCase {
    func testLongOutagesStartNewSegments() {
        for elapsed: TimeInterval in [300, 1200, 7200, 14400] {
            XCTAssertEqual(GPSContinuity.decision(elapsed: elapsed, distance: elapsed * 20, interrupted: false), .newSegment)
        }
    }

    func testImpossibleJumpIsRejectedEvenAfterGap() {
        XCTAssertEqual(GPSContinuity.decision(elapsed: 5, distance: 5000, interrupted: false), .reject)
        XCTAssertEqual(GPSContinuity.decision(elapsed: 300, distance: 300000, interrupted: true), .reject)
        XCTAssertEqual(GPSContinuity.decision(elapsed: 10, distance: 100, interrupted: true), .newSegment)
    }

    func testNormalMotionAndInvalidTimes() {
        XCTAssertEqual(GPSContinuity.decision(elapsed: 5, distance: 100, interrupted: false), .continuous)
        XCTAssertEqual(GPSContinuity.decision(elapsed: 0, distance: 0, interrupted: false), .reject)
        XCTAssertEqual(GPSContinuity.decision(elapsed: -1, distance: 0, interrupted: false), .reject)
        XCTAssertEqual(GPSContinuity.decision(elapsed: 1, distance: .nan, interrupted: false), .reject)
    }

    func testGapAndEstimateRoundTripIndependently() throws {
        let gap = GPSGap(id: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 0),
                         endedAt: Date(timeIntervalSince1970: 7200),
                         from: GPSCoordinate(latitude: 55, longitude: 37),
                         to: GPSCoordinate(latitude: 56, longitude: 38), reason: "GPS unavailable")
        let decoded = try JSONDecoder().decode(GPSGap.self, from: JSONEncoder().encode(gap))
        XCTAssertEqual(decoded.duration, 7200)
        XCTAssertTrue(decoded.isLong)
        XCTAssertEqual(decoded.to, gap.to)
        let estimate = GPSRouteEstimate(gapID: gap.id, calculatedAt: Date(),
            coordinates: [gap.from!, gap.to!], distanceMeters: 150000, expectedTravelTime: 8000,
            source: "Apple Maps automobile — candidate only")
        let saved = try JSONDecoder().decode(GPSRouteEstimate.self, from: JSONEncoder().encode(estimate))
        XCTAssertEqual(saved.gapID, gap.id)
        XCTAssertEqual(saved.distanceMeters, 150000)
        // No inferred coordinate or distance is stored in the measured gap.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(gap), as: UTF8.self).contains("distanceMeters"))
    }

    func testOpenEndedGapDecodesWithoutDestination() throws {
        let gap = GPSGap(id: UUID().uuidString, startedAt: Date(timeIntervalSince1970: 0),
                         endedAt: Date(timeIntervalSince1970: 300),
                         from: GPSCoordinate(latitude: 55, longitude: 37), to: nil, reason: "ride ended")
        let decoded = try JSONDecoder().decode(GPSGap.self, from: JSONEncoder().encode(gap))
        XCTAssertNil(decoded.to)
    }
}
