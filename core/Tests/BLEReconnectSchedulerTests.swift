import Foundation
import XCTest
@testable import MotoLinkCore

final class BLEReconnectSchedulerTests: XCTestCase {
    func testActualDeadlineHoldsImmediateFailureCallbacks() {
        var scheduler = BLEReconnectScheduler()
        let ticket = scheduler.schedule(after: 60, now: 100)!
        // Regression: iOS rejected the delayed connect option in milliseconds.
        // Merely logging a 60-second delay must not count as waiting for it.
        for tick in 0..<60000 {
            XCTAssertFalse(scheduler.consume(ticket, now: 100 + Double(tick) / 1000))
        }
        XCTAssertTrue(scheduler.consume(ticket, now: 160))
        XCTAssertFalse(scheduler.consume(ticket, now: 160))
    }

    func testFortyMinuteInstantFailureRunCannotBecomeCallbackStorm() {
        var retry = BLEReconnectPolicy()
        var scheduler = BLEReconnectScheduler()
        var now = 0.0
        var attempts: [Double] = []
        while now <= 2400 {
            let delay = retry.nextDelay(allowed: true)!
            let ticket = scheduler.schedule(after: delay, now: now)!
            if delay > 0 {
                XCTAssertFalse(scheduler.consume(ticket, now: now + 0.001))
            }
            now += delay
            guard now <= 2400 else { break }
            XCTAssertTrue(scheduler.consume(ticket, now: now))
            attempts.append(now)
            retry.connectionStarted()
            now += 0.003 // Real log's near-immediate invalid-parameter callback.
        }
        XCTAssertEqual(Array(attempts.prefix(6)).map { Int($0) }, [0, 2, 7, 22, 52, 112])
        XCTAssertLessThanOrEqual(attempts.count, 45)
        XCTAssertGreaterThan(attempts.count, 5) // Recovery remains unlimited.
        for interval in zip(attempts.dropFirst(6), attempts.dropFirst(5)) {
            XCTAssertGreaterThanOrEqual(interval.0 - interval.1, 60)
        }
    }

    func testFourHourFailureRunKeepsRetryingAtBoundedRate() {
        var retry = BLEReconnectPolicy()
        var scheduler = BLEReconnectScheduler()
        var now = 0.0
        var count = 0
        while now < 14400 {
            let ticket = scheduler.schedule(after: retry.nextDelay(allowed: true)!, now: now)!
            now = ticket.notBefore
            XCTAssertTrue(scheduler.consume(ticket, now: now))
            retry.connectionStarted()
            count += 1
            now += 0.003
        }
        XCTAssertLessThanOrEqual(count, 245)
        XCTAssertGreaterThan(count, 200)
    }

    func testStopOrPowerOffCancelsOldCallback() {
        var scheduler = BLEReconnectScheduler()
        let old = scheduler.schedule(after: 60, now: 0)!
        scheduler.cancel()
        XCTAssertNil(scheduler.pending)
        XCTAssertFalse(scheduler.consume(old, now: 10000))
    }

    func testNewDeviceOrManualConnectInvalidatesPriorDeadline() {
        var scheduler = BLEReconnectScheduler()
        let old = scheduler.schedule(after: 60, now: 0)!
        let replacement = scheduler.schedule(after: 0, now: 20)!
        XCTAssertFalse(scheduler.consume(old, now: 60))
        XCTAssertTrue(scheduler.consume(replacement, now: 60))
    }

    func testForegroundAndTimerCannotBothIssueSameConnect() {
        var scheduler = BLEReconnectScheduler()
        let ticket = scheduler.schedule(after: 30, now: 100)!
        // A foreground callback can resume an expired deadline after suspension.
        XCTAssertTrue(scheduler.consume(ticket, now: 1000))
        XCTAssertFalse(scheduler.consume(ticket, now: 1000))
        XCTAssertNil(scheduler.pending)
    }

    func testEarlyTimerMustWaitRemainingInterval() {
        var scheduler = BLEReconnectScheduler()
        let ticket = scheduler.schedule(after: 5, now: 100)!
        XCTAssertEqual(scheduler.remaining(for: ticket, now: 102), 3)
        XCTAssertFalse(scheduler.consume(ticket, now: 104.999))
        XCTAssertTrue(scheduler.consume(ticket, now: 105))
    }

    func testInvalidClockDoesNotIssueConnection() {
        var scheduler = BLEReconnectScheduler()
        let ticket = scheduler.schedule(after: 5, now: 100)!
        for now in [Double.nan, .infinity, -1] {
            XCTAssertNil(scheduler.remaining(for: ticket, now: now))
            XCTAssertFalse(scheduler.consume(ticket, now: now))
        }
        XCTAssertFalse(scheduler.consume(ticket, now: 50))
        XCTAssertTrue(scheduler.consume(ticket, now: 105))
    }

    func testInvalidScheduleNeverBorrowsAnEarlierTicket() {
        var scheduler = BLEReconnectScheduler()
        let old = scheduler.schedule(after: 60, now: 0)!
        for delay in [Double.nan, .infinity, -1] {
            XCTAssertNil(scheduler.schedule(after: delay, now: 100))
            XCTAssertFalse(scheduler.consume(old, now: 1000))
        }
        XCTAssertNil(scheduler.schedule(after: 60, now: .infinity))
    }

    func testIssuedConnectionHasNoDeadlineToCancelOrRepeat() {
        var scheduler = BLEReconnectScheduler()
        let ticket = scheduler.schedule(after: 0, now: 100)!
        XCTAssertTrue(scheduler.consume(ticket, now: 100))
        // A radio connection can remain pending for hours. The scheduler has
        // nothing left to expire; only a real failure can schedule another.
        for now in stride(from: 101.0, through: 14400, by: 60) {
            XCTAssertFalse(scheduler.consume(ticket, now: now))
        }
        XCTAssertNil(scheduler.pending)
    }
}
