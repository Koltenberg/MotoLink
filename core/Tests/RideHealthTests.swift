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

    private func value(_ id: String, _ value: Double, seconds: Double = 0) -> MotoProtocol.Measurement {
        .init(id: id, label: id, value: value, unit: "", timestamp: start.addingTimeInterval(seconds), source: "test")
    }

    func testActivityCombinesMovementEngineAndTemperature() {
        let state = BikeActivitySnapshot.sample(connected: true, ready: true, measurements: [
            value("wheel_speed", 60), value("engine_speed", 5000), value("engine_water_temperature", 75)
        ], now: start)
        XCTAssertTrue(state.live && state.moving && state.running)
        XCTAssertEqual(state.engineLevel, 3)
        XCTAssertEqual(state.temperature, 75)
        XCTAssertEqual(state.thermalLevel, 5)
    }

    func testActivityDoesNotPretendLostDataMeansStoppedEngine() {
        let values = [value("wheel_speed", 50), value("engine_speed", 4000), value("engine_water_temperature", 70)]
        let stale = BikeActivitySnapshot.sample(connected: true, ready: true, measurements: values,
            now: start.addingTimeInterval(4))
        XCTAssertFalse(stale.live || stale.moving || stale.running)
        XCTAssertNil(stale.engineLevel)
        XCTAssertEqual(stale.temperature, 70) // Slower temperature polling remains independent.
        XCTAssertEqual(stale.label, "Ждём свежие данные")
        let lost = BikeActivitySnapshot.sample(connected: false, ready: false, measurements: values, now: start)
        XCTAssertFalse(lost.live)
        XCTAssertNil(lost.temperature)
        let old = BikeActivitySnapshot.sample(connected: true, ready: true, measurements: values,
            now: start.addingTimeInterval(31))
        XCTAssertNil(old.temperature)
    }

    func testActivityRejectsFutureInvalidAndUnsupportedReadings() {
        let state = BikeActivitySnapshot.sample(connected: true, ready: true, measurements: [
            value("engine_speed", .nan), value("wheel_speed", 30, seconds: 1),
            value("engine_water_temperature", .infinity), value("gear_position", 3)
        ], now: start)
        XCTAssertFalse(state.live)
        XCTAssertNil(state.temperature)
        XCTAssertNil(state.engineLevel)
    }

    func testActivityUsesMeasuredZeroAndCapsVisualLevels() {
        let stopped = BikeActivitySnapshot.sample(connected: true, ready: true, measurements: [
            value("engine_speed", 0), value("wheel_speed", 0), value("engine_water_temperature", -30)
        ], now: start)
        XCTAssertTrue(stopped.live)
        XCTAssertFalse(stopped.moving || stopped.running)
        XCTAssertEqual(stopped.engineLevel, 0)
        XCTAssertEqual(stopped.thermalLevel, 0)
        XCTAssertEqual(stopped.label, "Двигатель остановлен")
        let high = BikeActivitySnapshot.sample(connected: true, ready: true, measurements: [
            value("engine_speed", 14000), value("engine_water_temperature", 160)
        ], now: start)
        XCTAssertEqual(high.engineLevel, 4)
        XCTAssertEqual(high.thermalLevel, 8)
    }
}
