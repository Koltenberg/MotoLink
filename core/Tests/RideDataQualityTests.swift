import XCTest
@testable import MotoLinkCore

final class RideDataQualityTests: XCTestCase {
    func testIsolatedQualityIslandAfterGPSOutageNeverBecomesMaximum() {
        var filter = GPSSpeedRecovery()
        let start = Date(timeIntervalSince1970: 1000)
        let observations: [(Double, Double, Double)] = [
            (68, 26, 180), (68, 25, 98), (65, 14, 106),
            (64, 13, 97), (63.7, 13, 25), (63.5, 14, 180), (59, 21, 180)]
        for (index, sample) in observations.enumerated() {
            XCTAssertNil(filter.accept(speed: sample.0, speedAccuracy: 1.3,
                horizontalAccuracy: sample.1, courseAccuracy: sample.2,
                at: start.addingTimeInterval(Double(index))))
        }
        XCTAssertNil(filter.accept(speed: 42, speedAccuracy: 1, horizontalAccuracy: 5,
            courseAccuracy: 3, at: start.addingTimeInterval(8)))
        XCTAssertEqual(filter.accept(speed: 42.3, speedAccuracy: 1, horizontalAccuracy: 5,
            courseAccuracy: 3, at: start.addingTimeInterval(9)), 42.3)
    }

    func testRecoveryDoesNotSmoothFastOrStationaryValidData() {
        var filter = GPSSpeedRecovery()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(filter.accept(speed: 60, speedAccuracy: 1, horizontalAccuracy: 5,
            courseAccuracy: 3, at: start))
        for (index, speed) in [61.0, 60.5, 57, 45, 15, 0].enumerated() {
            XCTAssertEqual(filter.accept(speed: speed, speedAccuracy: 1, horizontalAccuracy: 5,
                courseAccuracy: speed == 0 ? -1 : 3,
                at: start.addingTimeInterval(Double(index + 1))), speed)
        }
    }

    func testRecoveryCannotBeConfirmedByDuplicatesOrAcrossLongSilence() {
        var filter = GPSSpeedRecovery()
        func receive(_ time: Double) -> Double? {
            filter.accept(speed: 10, speedAccuracy: 1, horizontalAccuracy: 5, courseAccuracy: 3,
                          at: Date(timeIntervalSince1970: time))
        }
        XCTAssertNil(receive(1000))
        XCTAssertNil(receive(1000))
        XCTAssertNil(receive(999))
        XCTAssertEqual(receive(1001), 10)
        XCTAssertNil(receive(1020))
        XCTAssertEqual(receive(1021), 10)
        filter.reset()
        XCTAssertNil(receive(1022))
    }

    func testPoorStationaryPositionStillBreaksRecovery() {
        var filter = GPSSpeedRecovery()
        for (index, accuracy) in [5.0, 5, 200, 5, 5].enumerated() {
            let result = filter.accept(speed: 0, speedAccuracy: 1, horizontalAccuracy: accuracy,
                courseAccuracy: -1, at: Date(timeIntervalSince1970: 1000 + Double(index)))
            if index == 1 || index == 4 { XCTAssertEqual(result, 0) }
            else { XCTAssertNil(result) }
        }
    }
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

    func testReplayMergesOnlyFramesArrivingWhileOlderJournalIsRestored() throws {
        var baseline = RideTelemetryCoverage()
        baseline.receive(at: Date(timeIntervalSince1970: 1000))
        baseline.receive(at: Date(timeIntervalSince1970: 1001))
        var replayed = baseline
        replayed.receive(at: Date(timeIntervalSince1970: 1002))
        // The process-restored baseline deliberately has no previous frame.
        var live = try JSONDecoder().decode(RideTelemetryCoverage.self, from: JSONEncoder().encode(baseline))
        live.receive(at: Date(timeIntervalSince1970: 2000))
        live.receive(at: Date(timeIntervalSince1970: 2001))
        replayed.mergeLiveDelta(live, since: baseline)
        XCTAssertEqual(replayed.frameCount, 5)
        XCTAssertEqual(replayed.observedSeconds, 3)
        XCTAssertEqual(replayed.lastFrameAt, Date(timeIntervalSince1970: 2001))
        replayed.receive(at: Date(timeIntervalSince1970: 2002))
        XCTAssertEqual(replayed.observedSeconds, 4)
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
