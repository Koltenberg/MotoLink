import XCTest
@testable import MotoLinkCore

final class RideDataQualityTests: XCTestCase {
    func testRecordedGPSOutageSpikeIsNotARecordSpeed() {
        XCTAssertNil(GPSSpeedQuality.accepted(speed: 86.85391998291016,
            speedAccuracy: 1.1597, horizontalAccuracy: 23.0685, courseAccuracy: 180))
        XCTAssertNil(GPSSpeedQuality.accepted(speed: 83.4541,
            speedAccuracy: 2.2249, horizontalAccuracy: 11.5876, courseAccuracy: 92.572))
    }
    func testSpeedRequiresKnownFiniteAccuracy() {
        for accuracy in [-1.0, .nan, .infinity, 8.01] {
            XCTAssertNil(GPSSpeedQuality.accepted(speed: 20, speedAccuracy: accuracy,
                horizontalAccuracy: 5, courseAccuracy: 3))
        }
        XCTAssertNil(GPSSpeedQuality.accepted(speed: .nan, speedAccuracy: 1,
            horizontalAccuracy: 5, courseAccuracy: 3))
        XCTAssertNil(GPSSpeedQuality.accepted(speed: 20, speedAccuracy: 1,
            horizontalAccuracy: 26, courseAccuracy: 3))
    }
    func testStationarySpeedDoesNotNeedDirectionAndGoodFastDataIsRetained() {
        XCTAssertEqual(GPSSpeedQuality.accepted(speed: 0, speedAccuracy: 1,
            horizontalAccuracy: 5, courseAccuracy: -1), 0)
        XCTAssertEqual(GPSSpeedQuality.accepted(speed: 60, speedAccuracy: 1,
            horizontalAccuracy: 5, courseAccuracy: 8), 60)
        XCTAssertNil(GPSSpeedQuality.accepted(speed: 20, speedAccuracy: 1,
            horizontalAccuracy: 5, courseAccuracy: -1))
    }
    func testCoverageExcludesOutagesDisconnectsAndDuplicateFrames() {
        let start = Date(timeIntervalSince1970: 1000)
        var coverage = RideTelemetryCoverage()
        for seconds in [0.0, 1, 2, 2, 1, 62, 63] {
            coverage.receive(at: start.addingTimeInterval(seconds))
        }
        XCTAssertEqual(coverage.frameCount, 5)
        XCTAssertEqual(coverage.observedSeconds, 3)
        coverage.endSegment()
        coverage.receive(at: start.addingTimeInterval(64))
        XCTAssertEqual(coverage.observedSeconds, 3)
    }
    func testCoverageRestartDoesNotBridgeTimeWithoutCallbacks() throws {
        var coverage = RideTelemetryCoverage()
        coverage.receive(at: Date(timeIntervalSince1970: 1000))
        coverage.receive(at: Date(timeIntervalSince1970: 1001))
        let saved = try JSONEncoder().encode(coverage)
        var restored = try JSONDecoder().decode(RideTelemetryCoverage.self, from: saved)
        restored.receive(at: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(restored.observedSeconds, 1)
        XCTAssertEqual(restored.frameCount, 3)
    }
}
