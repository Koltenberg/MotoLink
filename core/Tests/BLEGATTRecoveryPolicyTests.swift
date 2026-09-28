import XCTest
@testable import MotoLinkCore

final class BLEGATTRecoveryPolicyTests: XCTestCase {
    private func readyPolicy() -> BLEGATTRecoveryPolicy {
        var policy = BLEGATTRecoveryPolicy()
        policy.beginConnection()
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), true)
        return policy
    }

    func testServiceChangeRediscoveryStaysOnOnePhysicalConnection() {
        var policy = readyPolicy()
        XCTAssertTrue(policy.beginServiceRediscovery())
        XCTAssertEqual(policy.phase, .discoveringServices)
        XCTAssertFalse(policy.beginServiceRediscovery())
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), false)
        XCTAssertEqual(policy.phase, .ready)
        XCTAssertFalse(policy.beginServiceRediscovery())
        policy.beginConnection()
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), true)
    }

    func testNotificationFailureRetriesExactlyOnceThenPreservesUnavailableState() {
        var policy = readyPolicy()
        XCTAssertTrue(policy.retryNotification("notify-4A", permitted: true))
        XCTAssertEqual(policy.phase, .subscribing)
        XCTAssertFalse(policy.retryNotification("notify-4A", permitted: true))
        policy.markUnavailable()
        XCTAssertEqual(policy.phase, .unavailable)
        XCTAssertNil(policy.notificationsReady())
        XCTAssertFalse(policy.beginServiceRediscovery())
    }

    func testFailedInitialSubscriptionCanRecoverWithoutSecondReadyBoundary() {
        var policy = BLEGATTRecoveryPolicy()
        policy.beginConnection()
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertTrue(policy.retryNotification("notify-4A", permitted: true))
        XCTAssertEqual(policy.notificationsReady(), true)
        XCTAssertTrue(policy.everReady)
        XCTAssertTrue(policy.retryNotification("notify-45", permitted: true))
        XCTAssertEqual(policy.notificationsReady(), false)
    }

    func testStaleCallbacksCannotAdvanceUnexpectedPhase() {
        var policy = BLEGATTRecoveryPolicy()
        XCTAssertFalse(policy.servicesDiscovered())
        XCTAssertFalse(policy.characteristicsDiscovered())
        XCTAssertNil(policy.notificationsReady())
        policy.beginConnection()
        XCTAssertFalse(policy.characteristicsDiscovered())
        policy.markUnavailable()
        XCTAssertFalse(policy.servicesDiscovered())
        XCTAssertFalse(policy.retryNotification("notify-4A", permitted: true))
        XCTAssertNil(policy.notificationsReady())
    }

    func testExplicitDiscoveryFailuresGetOneInPlaceRetryPerPhase() {
        var policy = BLEGATTRecoveryPolicy()
        policy.beginConnection()
        XCTAssertTrue(policy.retryServices())
        XCTAssertFalse(policy.retryServices())
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.retryCharacteristics())
        XCTAssertFalse(policy.retryCharacteristics())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), true)
        XCTAssertTrue(policy.beginServiceRediscovery())
        XCTAssertTrue(policy.retryServices())
        XCTAssertFalse(policy.retryServices())
    }

    func testNonNotifiableCharacteristicCannotTriggerRetry() {
        var policy = readyPolicy()
        XCTAssertFalse(policy.retryNotification("notify-4A", permitted: false))
        policy.markUnavailable()
        XCTAssertEqual(policy.phase, .unavailable)
    }
}
