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

    func testChartSeriesConnectsOnlyAdjacentBinsWithinObservedContinuity() {
        var series = RideChartSeries(binCount: 10, span: 100, maximumSilence: 15)
        series.append(offset: 11, value: 20)
        series.append(offset: 21, value: 30)
        XCTAssertTrue(series.connects(1, to: 2))
        series.append(offset: 41, value: 40)
        XCTAssertFalse(series.connects(2, to: 4))
        XCTAssertEqual(series.buckets[3].count, 0)
        XCTAssertFalse(series.connects(2, to: 3))
        XCTAssertEqual(series.gapCount, 1)
    }

    func testChartSeriesBreaksNeighboringBinsAfterSilenceOrExplicitInterruption() {
        var silence = RideChartSeries(binCount: 10, span: 100, maximumSilence: 5)
        silence.append(offset: 5, value: 10)
        silence.append(offset: 10, value: 20)
        XCTAssertTrue(silence.connects(0, to: 1))
        silence.append(offset: 13, value: 30)
        silence.append(offset: 21, value: 40)
        XCTAssertFalse(silence.connects(1, to: 2))
        XCTAssertEqual(silence.gapCount, 1)

        var interrupted = RideChartSeries(binCount: 10, span: 100, maximumSilence: 15)
        interrupted.append(offset: 9, value: 10)
        interrupted.append(offset: 11, value: 20, interrupted: true)
        XCTAssertFalse(interrupted.connects(0, to: 1))
        XCTAssertEqual(interrupted.gapCount, 1)
    }

    func testChartSeriesDiscardsPreGapValuesWhenOutageFitsInsideOneBin() {
        var series = RideChartSeries(binCount: 10, span: 1000, maximumSilence: 15)
        series.append(offset: 105, value: 10)
        series.append(offset: 125, value: 90)
        XCTAssertEqual(series.buckets[1].count, 1)
        XCTAssertEqual(series.buckets[1].mean, 90)
        XCTAssertEqual(series.gapCount, 2) // leading silence and the in-bin outage
        series.append(offset: 1001, value: 100)
        series.append(offset: 120, value: 5) // out of order
        series.append(offset: 1000, value: 50) // final timestamp stays in the last bin
        XCTAssertEqual(series.buckets[1].count, 1)
        XCTAssertEqual(series.buckets[9].count, 1)
        XCTAssertEqual(series.buckets.count, 10)
    }
}
