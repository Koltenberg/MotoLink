import Foundation
import XCTest
@testable import MotoLinkCore

final class TelemetryPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private var capabilities: [MotoProtocol.Capability] {
        [cap("ecu_battery12V", 0), cap("engine_water_temperature", 1), cap("inlet_air_temperature", 1),
         cap("fuel_injection", 0), cap("wheel_speed", 1), cap("engine_speed", 0), cap("gear_position", 1), cap("throttle_position", 1)]
    }
    private func cap(_ id: String, _ mode: UInt8) -> MotoProtocol.Capability { .init(id: id, label: id, mode: mode) }
    private func sample(_ id: String, value: Double = 20, at: Date? = nil) -> MotoProtocol.Measurement {
        .init(id: id, label: id, value: value, unit: "", timestamp: at ?? now, source: "test")
    }
    private func stream(sentinel: Bool = false) -> Data {
        var bytes = Array(repeating: UInt8(0xFF), count: 85)
        bytes[0] = 0x4A; bytes[1] = 82; bytes[5] = 5; bytes[6] = 0x18
        if !sentinel {
            bytes[7] = 0; bytes[8] = 20; bytes[9] = 0; bytes[10] = 40
            bytes[11] = 8; bytes[12] = 0; bytes[13] = 2
        }
        bytes[14] = 0 // Zero throttle is a measured value, not missing data.
        return Data(bytes)
    }
    private func row(_ state: TelemetryPresentation, _ id: String, at: Date? = nil, connected: Bool = true) -> TelemetryPresentation.Row {
        state.rows(connected: connected, ready: true, now: at ?? now).first { $0.id == id }!
    }

    func testCapabilitiesCreateEightStableRowsBeforeAnyValueArrives() {
        var state = TelemetryPresentation()
        state.configure(capabilities)
        XCTAssertEqual(state.fields.map(\.id), ["wheel_speed", "gear_position", "engine_speed", "engine_water_temperature",
            "throttle_position", "ecu_battery12V", "inlet_air_temperature", "fuel_injection_raw"])
        XCTAssertEqual(state.rows(connected: true, ready: true, now: now).filter { $0.state == .waiting }.count, 8)
        XCTAssertTrue(state.measurements.isEmpty)
    }

    func testAlternatingFastSlowFramesAndSentinelsNeverChangeRowIdentityOrOrder() {
        var state = TelemetryPresentation()
        state.configure(capabilities)
        let ids = state.fields.map(\.id)
        for index in 0..<1200 {
            let frame = stream(sentinel: index % 2 == 1)
            state.receive(frame, decoded: MotoProtocol.measurements(frame, capabilities: capabilities, at: now))
            if index % 5 == 0 {
                state.receive(Data([0x45, 2, 0, 0, 0]), decoded: [sample("engine_water_temperature", value: 75)])
            }
            XCTAssertEqual(state.fields.map(\.id), ids)
            XCTAssertEqual(state.rows(connected: true, ready: true, now: now).count, 8)
        }
        XCTAssertNil(row(state, "engine_speed").value)
        XCTAssertEqual(row(state, "throttle_position").value, 0)
    }

    func testMissingCurrentValueNeverShowsPreviousValueAsLive() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(stream(), decoded: [sample("engine_speed", value: 5000), sample("wheel_speed", value: 70)])
        state.receive(stream(sentinel: true), decoded: [])
        XCTAssertEqual(row(state, "engine_speed").state, .waiting)
        XCTAssertNil(row(state, "engine_speed").measurement)
        XCTAssertNil(row(state, "wheel_speed").value)
        XCTAssertEqual(state.fields.count, 8)
    }

    func testIndependentChannelsDoNotRemoveEachOthersValues() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(Data([0x45, 2, 0, 0, 0]), decoded: [sample("engine_water_temperature", value: 75)])
        state.receive(stream(), decoded: [sample("engine_speed", value: 5000)])
        XCTAssertEqual(row(state, "engine_water_temperature").value, 75)
        XCTAssertEqual(row(state, "engine_speed").value, 5000)
    }

    func testMalformedEnvelopePreservesSampleTimeWithoutRefreshingIt() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(stream(), decoded: [sample("engine_speed", value: 5000)])
        state.receive(Data([0x4A, 82, 0]), decoded: [])
        XCTAssertEqual(row(state, "engine_speed").measurement?.timestamp, now)
        XCTAssertNil(row(state, "engine_speed", at: now.addingTimeInterval(4)).value)
    }

    func testEachChannelExpiresAndFutureSampleIsNotFresh() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(Data([0, 0, 0]), decoded: [sample("engine_speed"), sample("engine_water_temperature"), sample("ecu_battery12V")])
        XCTAssertEqual(row(state, "engine_speed", at: now.addingTimeInterval(3)).value, 20)
        XCTAssertNil(row(state, "engine_speed", at: now.addingTimeInterval(3.01)).value)
        XCTAssertEqual(row(state, "engine_water_temperature", at: now.addingTimeInterval(30)).value, 20)
        XCTAssertNil(row(state, "engine_water_temperature", at: now.addingTimeInterval(31)).value)
        XCTAssertEqual(row(state, "ecu_battery12V", at: now.addingTimeInterval(90)).value, 20)
        XCTAssertNil(row(state, "ecu_battery12V", at: now.addingTimeInterval(91)).value)
        XCTAssertNil(row(state, "engine_speed", at: now.addingTimeInterval(-1)).value)
    }

    func testDisconnectAndReconnectKeepRowsButNoNumericReadings() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(stream(), decoded: [sample("engine_speed", value: 5000)])
        XCTAssertNil(row(state, "engine_speed", connected: false).value)
        let ids = state.fields.map(\.id)
        state.invalidateReadings()
        state.configure(Array(capabilities.reversed()))
        XCTAssertEqual(state.fields.map(\.id), ids)
        XCTAssertTrue(state.measurements.isEmpty)
    }

    func testChangedCapabilityStaysInPlaceAsUnavailableAndHasNoOldValue() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(stream(), decoded: [sample("engine_speed", value: 5000)])
        let ids = state.fields.map(\.id)
        state.configure(capabilities.filter { $0.id != "engine_speed" })
        XCTAssertEqual(state.fields.map(\.id), ids)
        XCTAssertEqual(row(state, "engine_speed").state, .unavailable)
        XCTAssertNil(row(state, "engine_speed").value)
    }

    func testUnknownSupportedFormatsAreHonestAndUnsupportedAreNotAdvertised() {
        var state = TelemetryPresentation()
        state.configure([cap("odometer", 0), cap("engine_speed", 1), cap("lean_angle", 2)])
        XCTAssertEqual(state.fields.count, 2)
        XCTAssertEqual(row(state, "odometer").state, .notDecoded)
        XCTAssertEqual(row(state, "engine_speed").state, .notDecoded)
        XCTAssertFalse(state.fields.contains { $0.id == "lean_angle" })
    }

    func testInvalidAndUnknownValuesDoNotInventRowsOrMeasurements() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state.receive(stream(), decoded: [sample("engine_speed", value: .nan), sample("wheel_speed", value: .infinity), sample("unknown")])
        XCTAssertTrue(state.measurements.isEmpty)
        XCTAssertEqual(state.fields.count, 8)
    }

    func testDifferentBikeStartsWithAnEmptyCatalogue() {
        var state = TelemetryPresentation(); state.configure(capabilities)
        state = TelemetryPresentation()
        state.configure([cap("ecu_battery12V", 0)])
        XCTAssertEqual(state.fields.map(\.id), ["ecu_battery12V"])
    }

    func testPrimaryPlaceholderDistinguishesWaitingFromUnsupportedAndNotReady() {
        var state = TelemetryPresentation()
        let speed = TelemetryPresentation.placeholder("wheel_speed")
        XCTAssertEqual(state.row(speed, connected: true, ready: true, now: now).state, .waiting)
        state.configure([cap("wheel_speed", 2)])
        XCTAssertEqual(state.row(speed, connected: true, ready: true, now: now).state, .unavailable)
        XCTAssertEqual(state.row(speed, connected: true, ready: false, now: now).state, .waiting)
        XCTAssertNil(state.row(speed, connected: true, ready: false, now: now).value)
    }
}
