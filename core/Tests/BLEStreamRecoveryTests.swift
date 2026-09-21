import Foundation
import XCTest
@testable import MotoLinkCore

final class BLEStreamRecoveryTests: XCTestCase {
    func testNoPreviouslyObservedStreamNeverChangesProfile() {
        var policy = BLEStreamRecoveryPolicy()
        for time in stride(from: 0.0, through: 7200, by: 15) {
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
        XCTAssertFalse(policy.rearmUsed)
    }

    func testHealthyFortyMinuteStreamDoesNotGenerateCommands() {
        var policy = BLEStreamRecoveryPolicy()
        for packet in 0...12000 {
            let time = Double(packet) / 5
            policy.receivedStream(at: time)
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
        XCTAssertFalse(policy.rearmUsed)
    }

    func testLostStreamRearmsOnceThenRestartsAfterGrace() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 100)
        XCTAssertNil(policy.nextAction(at: 144.99, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 145, eligible: true), .rearmStream)
        for time in stride(from: 145.01, through: 174.99, by: 0.1) {
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
        XCTAssertEqual(policy.nextAction(at: 175, eligible: true), .restartTransport)
        for time in 176...1000 { XCTAssertNil(policy.nextAction(at: Double(time), eligible: true)) }
    }

    func testBusyOrStoppedDoesNotConsumeRecoveryAndGraceStartsAtActualRearm() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertNil(policy.nextAction(at: 100, eligible: false))
        XCTAssertFalse(policy.rearmUsed)
        XCTAssertEqual(policy.nextAction(at: 200, eligible: true), .rearmStream)
        XCTAssertNil(policy.nextAction(at: 229, eligible: true))
        XCTAssertNil(policy.nextAction(at: 230, eligible: false))
        XCTAssertEqual(policy.nextAction(at: 300, eligible: true), .restartTransport)
    }

    func testReturningStreamCancelsEscalationWithoutRepeatedProfileWrites() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        policy.receivedStream(at: 46)
        XCTAssertNil(policy.nextAction(at: 75, eligible: true))
        policy.receivedStream(at: 76)
        XCTAssertNil(policy.nextAction(at: 120, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 121, eligible: true), .restartTransport)
    }

    func testResetRemovesPreviousSessionEvidenceAndRearmBudget() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        policy.reset()
        XCTAssertNil(policy.nextAction(at: 1000, eligible: true))
        policy.receivedStream(at: 1001)
        XCTAssertEqual(policy.nextAction(at: 1046, eligible: true), .rearmStream)
    }

    func testBackwardOrInvalidClockDoesNotForceRecovery() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 100)
        XCTAssertNil(policy.nextAction(at: 50, eligible: true))
        XCTAssertNil(policy.nextAction(at: 94, eligible: true))
        XCTAssertNil(policy.nextAction(at: .nan, eligible: true))
        XCTAssertNil(policy.nextAction(at: .infinity, eligible: true))
        XCTAssertNil(policy.nextAction(at: -1, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 95, eligible: true), .rearmStream)
        XCTAssertNil(policy.nextAction(at: 10, eligible: true))
        XCTAssertNil(policy.nextAction(at: 39, eligible: true))
        // The 45-second silence criterion remains in force after clock rebasing.
        XCTAssertEqual(policy.nextAction(at: 55, eligible: true), .restartTransport)
    }

    func testUnknownMeasurementLayoutStillProvesStreamIsAlive() {
        var bytes = [UInt8](repeating: 0xFF, count: 100)
        bytes[0] = 0x4A; bytes[1] = 97
        XCTAssertTrue(BLEStreamRecoveryPolicy.isStreamFrame(Data(bytes)))
        var policy = BLEStreamRecoveryPolicy()
        for time in stride(from: 0.0, through: 600, by: 1) {
            if BLEStreamRecoveryPolicy.isStreamFrame(Data(bytes)) { policy.receivedStream(at: time) }
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
    }

    func testTemperatureAndAckFramesDoNotHideLossOfPreviouslyWorkingStream() {
        var temperature = [UInt8](repeating: 0, count: 38)
        temperature[0] = 0x45; temperature[1] = 35
        XCTAssertFalse(BLEStreamRecoveryPolicy.isStreamFrame(Data(temperature)))
        XCTAssertFalse(BLEStreamRecoveryPolicy.isStreamFrame(Data([0x20, 2, 0, 8, 0])))
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        for time in 1..<45 {
            if BLEStreamRecoveryPolicy.isStreamFrame(Data(temperature)) { policy.receivedStream(at: Double(time)) }
            XCTAssertNil(policy.nextAction(at: Double(time), eligible: true))
        }
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
    }

    func testOtherTelemetryPreservesWorkingConnectionAfterOneRearm() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        var notices = 0
        for time in 46...7200 {
            policy.receivedPacket(at: Double(time)) // Valid 45/4B/unknown envelope.
            let action = policy.nextAction(at: Double(time), eligible: true)
            if action == .preserveActiveLink { notices += 1 }
            else { XCTAssertNil(action) }
        }
        XCTAssertEqual(notices, 1)
        XCTAssertFalse(policy.restartRequested)
        XCTAssertNil(policy.nextAction(at: 7229, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 7230, eligible: true), .restartTransport)
    }

    func testRearmAckDelaysTransportRestartUntilAllTrafficIsSilent() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        policy.receivedPacket(at: 70)
        XCTAssertEqual(policy.nextAction(at: 75, eligible: true), .preserveActiveLink)
        XCTAssertNil(policy.nextAction(at: 99, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 100, eligible: true), .restartTransport)
    }

    func testMalformedEnvelopeDoesNotPreventRecovery() {
        XCTAssertTrue(BLEStreamRecoveryPolicy.isPacket(Data([0x20, 2, 0, 8, 0])))
        XCTAssertTrue(BLEStreamRecoveryPolicy.isPacket(Data([0xFE, 0, 1])))
        XCTAssertFalse(BLEStreamRecoveryPolicy.isPacket(Data([0x45, 10, 0])))
        XCTAssertFalse(BLEStreamRecoveryPolicy.isPacket(Data()))
    }

    func testMalformedAndTruncatedFramesCannotArmWatchdog() {
        for data in [Data(), Data([0x4A]), Data([0x4A, 0, 0]),
                     Data([0x4A, 12, 0]), Data([UInt8](repeating: 0x4A, count: 15))] {
            XCTAssertFalse(BLEStreamRecoveryPolicy.isStreamFrame(data))
        }
    }

    func testRepeatedStallsRemainBoundedAcrossManyTransportAttempts() {
        var reconnect = BLEReconnectPolicy()
        for attempt in 0..<1000 {
            var stream = BLEStreamRecoveryPolicy()
            let start = Double(attempt) * 180
            stream.receivedStream(at: start)
            XCTAssertEqual(stream.nextAction(at: start + 45, eligible: true), .rearmStream)
            XCTAssertEqual(stream.nextAction(at: start + 75, eligible: true), .restartTransport)
            reconnect.requestTransportRestart()
            let delay = reconnect.nextDelay(allowed: true, cancelled: true)
            XCTAssertNotNil(delay)
            XCTAssertLessThanOrEqual(delay!, 60)
            reconnect.connectionStarted()
        }
    }
}
