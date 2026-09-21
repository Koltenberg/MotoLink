import Foundation
import XCTest
@testable import MotoLinkCore

final class MotoProtocolTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        let text = Array(hex)
        precondition(text.count % 2 == 0)
        return Data(stride(from: 0, to: text.count, by: 2).map {
            UInt8(String(text[$0..<$0 + 2]), radix: 16)!
        })
    }
    private var capabilities: [MotoProtocol.Capability] {
        MotoProtocol.capabilities(data("40209240000511FC77D417FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"))!
    }
    private var snapshot: Data {
        var b = [UInt8](repeating: 0xFF, count: 85)
        b.replaceSubrange(0..<15, with: [0x41, 0x52, 0x94, 0x41, 0x00, 0x05, 0x14, 0, 0, 0, 0, 0, 0, 0, 0x9F])
        return Data(b)
    }
    func testActualEX500GCapabilities() {
        let supported = capabilities.filter(\.supported)
        XCTAssertEqual(supported.count, 8)
        XCTAssertEqual(supported.first(where: { $0.id == "engine_speed" })?.mode, 0)
        XCTAssertEqual(supported.first(where: { $0.id == "wheel_speed" })?.mode, 1)
    }
    func testActualEX500GVoltageNeedsCapabilities() {
        let measured = MotoProtocol.measurements(snapshot, capabilities: capabilities)
        XCTAssertEqual(measured.count, 1)
        XCTAssertEqual(measured[0].value, 12.421875, accuracy: 0.000001)
        XCTAssertTrue(MotoProtocol.measurements(snapshot, capabilities: []).isEmpty)
        var missing = snapshot; missing[14] = 0xFF
        XCTAssertTrue(MotoProtocol.measurements(missing, capabilities: capabilities).isEmpty)
        var wrongBlock = snapshot; wrongBlock[6] = 0x17
        XCTAssertTrue(MotoProtocol.measurements(wrongBlock, capabilities: capabilities).isEmpty)
    }
    func testMalformedEnvelopeNeverProducesValues() {
        for length in 0..<snapshot.count {
            XCTAssertTrue(MotoProtocol.measurements(snapshot.prefix(length), capabilities: capabilities).isEmpty)
        }
        XCTAssertFalse(MotoProtocol.validEnvelope(data("2002934100"), command: 0x41))
        var unknown = snapshot; unknown[1] = 0
        XCTAssertTrue(MotoProtocol.measurements(unknown, capabilities: capabilities).isEmpty)
    }
    func testTemperatureUpstreamFixtureNotEX500GFieldValidation() {
        let frame = data("4534a4ffffffffffffffffffffffff05175000004c00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
        XCTAssertTrue(MotoProtocol.validEnvelope(frame, command: 0x45))
        let measurements = MotoProtocol.measurements(frame, capabilities: capabilities)
        XCTAssertEqual(measurements.map(\.value), [40, 36])
        XCTAssertTrue(measurements.allSatisfy { $0.source.contains("экспериментальный") })
        var missing = frame; missing[17] = 0xFF; missing[20] = 0xFF
        XCTAssertTrue(MotoProtocol.measurements(missing, capabilities: capabilities).isEmpty)
    }
    func testExperimentalStreamSyntheticOnly() {
        // Deliberately synthetic: guards arithmetic, not the real EX500G layout.
        var b: [UInt8] = [0x4A, 0x0C, 0, 0xFF, 0xFF, 0x05, 0x01, 0, 0, 0, 100, 0x17, 0x70, 3, 0xFF]
        let decoded = MotoProtocol.measurements(Data(b), capabilities: capabilities)
        XCTAssertEqual(decoded.first(where: { $0.id == "engine_speed" })?.value, 6000)
        XCTAssertEqual(decoded.first(where: { $0.id == "wheel_speed" })?.value, 100)
        XCTAssertEqual(decoded.first(where: { $0.id == "gear_position" })?.value, 3)
        XCTAssertEqual(decoded.first(where: { $0.id == "throttle_position" })?.value, 100)
        XCTAssertTrue(decoded.allSatisfy { $0.source.contains("экспериментально") })
        b[5] = 0xFF; b[6] = 0xFF
        XCTAssertTrue(MotoProtocol.measurements(Data(b), capabilities: capabilities).isEmpty)
        XCTAssertTrue(MotoProtocol.measurements(Data(b), capabilities: []).isEmpty)
    }
    func testOnlyKnownRequestProfilesAndLengths() {
        for command: UInt8 in [0x03, 0x40, 0x41, 0x45, 0x1A, 0x1D, 0x47, 0x08, 0x0B, 0x1B, 0x48, 0x1E] {
            let request = Array(MotoProtocol.request(command)!)
            XCTAssertEqual(request[0], command)
            XCTAssertEqual(request.count, Int(request[1]) + 3)
        }
        for command: UInt8 in [0x13, 0x42, 0x99, 0xFF] { XCTAssertNil(MotoProtocol.request(command)) }
        XCTAssertEqual(MotoProtocol.request(0x08), data("080c00ffff0a08017803e800c80064"))
    }
    func testCapabilityNotReadyAndUnknownBlocks() {
        var cap = data("40209240000511FC77D417FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
        cap[14] = 0
        XCTAssertNil(MotoProtocol.capabilities(cap))
        for index in 5..<35 { cap[index] = 0xFF }
        XCTAssertNil(MotoProtocol.capabilities(cap))
    }

    func testInjectionCandidateRetainsRawBitsWithoutPhysicalScale() {
        var b: [UInt8] = [0x4A, 0x0C, 0, 0xFF, 0xFF, 0x05, 0x01, 0x03, 0x87, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0]
        let raw = MotoProtocol.measurements(Data(b), capabilities: capabilities)
            .first { $0.id == "fuel_injection_raw" }
        XCTAssertEqual(raw?.value, 903)
        XCTAssertEqual(raw?.unit, "без единиц")
        b[7] = 0; b[8] = 0
        XCTAssertEqual(MotoProtocol.measurements(Data(b), capabilities: capabilities)
            .first { $0.id == "fuel_injection_raw" }?.value, 0)
    }

    func testInjectionSentinelOrUnsupportedCapabilityDoesNotBecomeData() {
        var b: [UInt8] = [0x4A, 0x0C, 0, 0xFF, 0xFF, 0x05, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0]
        XCTAssertNil(MotoProtocol.measurements(Data(b), capabilities: capabilities)
            .first { $0.id == "fuel_injection_raw" })
        b[7] = 1; b[8] = 2
        for mode: UInt8 in [2, 3] {
            let unsupported = [MotoProtocol.Capability(id: "fuel_injection", label: "test", mode: mode)]
            XCTAssertTrue(MotoProtocol.measurements(Data(b), capabilities: unsupported).isEmpty)
        }
    }
}
