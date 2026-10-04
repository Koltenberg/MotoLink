import Foundation
import XCTest
@testable import MotoLinkCore

final class BLEStreamRecoveryTests: XCTestCase {
    func testCompletedInitialProfileWriteErrorAllowsOneIdleRetryAfterGrace() {
        var policy = BLEStreamRecoveryPolicy()
        XCTAssertTrue(policy.initialProfileWriteFailed(at: 100))
        XCTAssertTrue(policy.initialProfileRetryPending)
        XCTAssertNil(policy.nextAction(at: 144.99, eligible: true))
        // The caller passes false while a write, diagnostic, or other request is active.
        XCTAssertNil(policy.nextAction(at: 145, eligible: false))
        XCTAssertTrue(policy.initialProfileRetryPending)
        XCTAssertEqual(policy.nextAction(at: 160, eligible: true), .retryInitialProfile)
        XCTAssertFalse(policy.initialProfileRetryPending)
        XCTAssertFalse(policy.initialProfileWriteFailed(at: 161))
        XCTAssertNil(policy.nextAction(at: 1000, eligible: true))
    }

    func testFirstValidStreamCancelsPendingStartupRetry() {
        var policy = BLEStreamRecoveryPolicy()
        policy.initialProfileWriteFailed(at: 100)
        policy.receivedStream(at: 110)
        XCTAssertFalse(policy.initialProfileRetryPending)
        for time in stride(from: 110.0, through: 200, by: 1) {
            policy.receivedStream(at: time)
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
    }

    func testWriteErrorAfterWorkingStreamCannotScheduleAnotherProfile() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 100)
        XCTAssertFalse(policy.initialProfileWriteFailed(at: 101))
        XCTAssertFalse(policy.initialProfileRetryPending)
        for time in stride(from: 101.0, through: 140, by: 1) {
            policy.receivedStream(at: time)
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
    }

    func testAnotherProfileAttemptSupersedesPendingStartupRetry() {
        var policy = BLEStreamRecoveryPolicy()
        policy.initialProfileWriteFailed(at: 100)
        policy.initialProfileStarted()
        XCTAssertFalse(policy.initialProfileRetryPending)
        XCTAssertNil(policy.nextAction(at: 1000, eligible: true))
        XCTAssertFalse(policy.initialProfileWriteFailed(at: 1001))
        XCTAssertNil(policy.nextAction(at: 2000, eligible: true))
    }

    func testMissingWriteCallbackNeverArmsStartupRetry() {
        var policy = BLEStreamRecoveryPolicy()
        for time in stride(from: 0.0, through: 7200, by: 15) {
            XCTAssertFalse(policy.initialProfileRetryPending)
            XCTAssertNil(policy.nextAction(at: time, eligible: false))
        }
    }

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

    func testLostStreamRearmsOnceThenKeepsConnectedLinkAfterGrace() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 100)
        XCTAssertNil(policy.nextAction(at: 144.99, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 145, eligible: true), .rearmStream)
        for time in stride(from: 145.01, through: 174.99, by: 0.1) {
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
        XCTAssertEqual(policy.nextAction(at: 175, eligible: true), .preserveSilentLink)
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
        XCTAssertEqual(policy.nextAction(at: 300, eligible: true), .preserveSilentLink)
    }

    func testReturningStreamAvoidsRepeatedProfileWrites() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        policy.receivedStream(at: 46)
        XCTAssertNil(policy.nextAction(at: 75, eligible: true))
        policy.receivedStream(at: 76)
        XCTAssertNil(policy.nextAction(at: 120, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 121, eligible: true), .preserveSilentLink)
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
        XCTAssertEqual(policy.nextAction(at: 55, eligible: true), .preserveSilentLink)
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
        XCTAssertNil(policy.nextAction(at: 7229, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 7230, eligible: true), .preserveSilentLink)
        for time in stride(from: 7231.0, through: 14400, by: 60) {
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
    }

    func testOtherPacketsRemainDistinguishableFromCompleteSilence() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        policy.receivedPacket(at: 70)
        XCTAssertEqual(policy.nextAction(at: 75, eligible: true), .preserveActiveLink)
        XCTAssertNil(policy.nextAction(at: 99, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 100, eligible: true), .preserveSilentLink)
    }

    func testMalformedEnvelopeDoesNotPreventRecovery() {
        XCTAssertTrue(BLEStreamRecoveryPolicy.isPacket(Data([0x20, 2, 0, 8, 0])))
        XCTAssertTrue(BLEStreamRecoveryPolicy.isPacket(Data([0xFE, 0, 1])))
        XCTAssertFalse(BLEStreamRecoveryPolicy.isPacket(Data([0x45, 10, 0])))
        XCTAssertFalse(BLEStreamRecoveryPolicy.isPacket(Data()))
    }

    func testSilentConnectedLinkDoesNotTriggerAnotherRecoveryOverFourHours() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        XCTAssertEqual(policy.nextAction(at: 75, eligible: true), .preserveSilentLink)
        for time in stride(from: 76.0, through: 14400, by: 1) {
            XCTAssertNil(policy.nextAction(at: time, eligible: true))
        }
        XCTAssertTrue(policy.rearmUsed)
    }

    func testMalformedAndTruncatedFramesCannotArmWatchdog() {
        for data in [Data(), Data([0x4A]), Data([0x4A, 0, 0]),
                     Data([0x4A, 12, 0]), Data([UInt8](repeating: 0x4A, count: 15))] {
            XCTAssertFalse(BLEStreamRecoveryPolicy.isStreamFrame(data))
        }
    }

    func testSecondSilenceAfterStreamReturnsDoesNotRearmAgain() {
        var policy = BLEStreamRecoveryPolicy()
        policy.receivedStream(at: 0)
        XCTAssertEqual(policy.nextAction(at: 45, eligible: true), .rearmStream)
        XCTAssertEqual(policy.nextAction(at: 75, eligible: true), .preserveSilentLink)
        policy.receivedStream(at: 100)
        XCTAssertNil(policy.nextAction(at: 144, eligible: true))
        XCTAssertEqual(policy.nextAction(at: 145, eligible: true), .preserveSilentLink)
        XCTAssertNil(policy.nextAction(at: 10000, eligible: true))
        XCTAssertTrue(policy.rearmUsed)
    }
}
