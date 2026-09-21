import Foundation
import XCTest
@testable import MotoLinkCore

final class SlowTelemetryPollingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1000)
    func queries(voltageAge: Double? = 1, temperatureAge: Double? = 1,
                 statusQueryAge: Double? = 60, temperatureQueryAge: Double? = 30,
                 voltageSupported: Bool = true, temperatureSupported: Bool = true) -> [UInt8] {
        SlowTelemetryPolling.commands(now: now, voltageSupported: voltageSupported,
            temperatureSupported: temperatureSupported,
            lastVoltageAt: voltageAge.map { now.addingTimeInterval(-$0) },
            lastTemperatureAt: temperatureAge.map { now.addingTimeInterval(-$0) },
            lastStatusRequestAt: statusQueryAge.map { now.addingTimeInterval(-$0) },
            lastTemperatureRequestAt: temperatureQueryAge.map { now.addingTimeInterval(-$0) })
    }
    func testLiveUnsolicitedTemperatureNeedsNoDuplicateQuery() {
        XCTAssertEqual(queries(), [])
        XCTAssertEqual(queries(voltageAge: 60), [0x41])
    }
    func testMissingTemperatureGetsBoundedFallback() {
        XCTAssertEqual(queries(temperatureAge: 15), [0x45])
        XCTAssertEqual(queries(temperatureAge: 100, temperatureQueryAge: 29), [])
        XCTAssertEqual(queries(temperatureAge: nil, temperatureQueryAge: 30), [0x45])
    }
    func testSlowStatusCannotBeRetriedAtEveryHealthTick() {
        XCTAssertEqual(queries(voltageAge: nil, statusQueryAge: 15), [])
        XCTAssertEqual(queries(voltageAge: nil, statusQueryAge: 60), [0x41])
    }
    func testUnsupportedCapabilitiesAreNotProbed() {
        XCTAssertEqual(queries(voltageAge: nil, temperatureAge: nil,
            voltageSupported: false, temperatureSupported: false), [])
    }
    func testMissingAndFutureTimestampsAreNotTreatedAsFresh() {
        XCTAssertEqual(queries(voltageAge: nil, temperatureAge: nil,
            statusQueryAge: nil, temperatureQueryAge: nil), [0x41, 0x45])
        XCTAssertEqual(queries(voltageAge: -1, temperatureAge: -1), [0x41, 0x45])
    }
    func testWarmupScalePreservesRealTemperatureAndUnknownValues() {
        func sample(_ water: Double?) -> BikeActivitySnapshot {
            let values: [MotoProtocol.Measurement] = water.map {
                [.init(id: "engine_water_temperature", label: "water", value: $0,
                       unit: "C", timestamp: now, source: "test")]
            } ?? []
            return BikeActivitySnapshot.sample(connected: true, ready: true, measurements: values, now: now)
        }
        XCTAssertNil(sample(nil).thermalLevel)
        XCTAssertEqual(sample(18).temperature, 18)
        XCTAssertEqual(sample(18).thermalLevel, 0)
        XCTAssertEqual(sample(40).thermalLevel, 0)
        XCTAssertEqual(sample(75).thermalLevel, 4)
        XCTAssertEqual(sample(105).thermalLevel, 8)
        XCTAssertEqual(sample(120).temperature, 120)
        XCTAssertEqual(sample(120).thermalLevel, 8)
    }
}
