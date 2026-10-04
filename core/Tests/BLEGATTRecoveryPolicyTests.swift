import XCTest
@testable import MotoLinkCore

final class BLEGATTRecoveryPolicyTests: XCTestCase {
    func testLateDiscoveryCompletionsAfterObservationDeadlineStillReachReady() {
        var policy = BLEGATTRecoveryPolicy()
        policy.beginConnection()
        // The 60-second observation may run before an original callback after
        // pairing/background delay. It neither spends retry nor closes setup.
        XCTAssertEqual(policy.pendingSetupAfterObservationTimeout(linkConnected: true), .discoveringServices)
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertEqual(policy.pendingSetupAfterObservationTimeout(linkConnected: true), .discoveringCharacteristics)
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.pendingSetupAfterObservationTimeout(linkConnected: true), .subscribing)
        XCTAssertEqual(policy.notificationsReady(), true)
        XCTAssertNil(policy.pendingSetupAfterObservationTimeout(linkConnected: true))
        XCTAssertFalse(policy.serviceRediscoveryUsed)
    }

    func testNotificationDeadlineRetainsPendingOperationUntilItsOwnCallback() {
        var policy = readyPolicy()
        var queue = BLENotificationQueue()
        queue.reset(restored: ["A", "B", "C"])
        queue.received("A", notifying: false)
        policy.notificationLost()
        XCTAssertTrue(policy.retryNotification("A", permitted: true))
        queue.requested("A")
        for _ in 0..<10 {
            XCTAssertEqual(policy.pendingSetupAfterObservationTimeout(linkConnected: true), .subscribing)
            XCTAssertEqual(queue.pending, "A")
            XCTAssertNil(queue.next(in: ["A", "B", "C"]))
        }
        queue.received("A", notifying: true)
        XCTAssertEqual(queue.confirmed, ["A", "B", "C"])
        XCTAssertEqual(policy.notificationsReady(), false)
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: true, ready: true), .send)
        // Accepting the original callback grants no new repair budget.
        XCTAssertFalse(policy.retryNotification("A", permitted: true))
    }

    func testObservationCannotResurrectFailedOrDisconnectedSetup() {
        var policy = BLEGATTRecoveryPolicy()
        XCTAssertNil(policy.pendingSetupAfterObservationTimeout(linkConnected: true))
        policy.beginConnection()
        XCTAssertNil(policy.pendingSetupAfterObservationTimeout(linkConnected: false))
        policy.markUnavailable()
        XCTAssertNil(policy.pendingSetupAfterObservationTimeout(linkConnected: true))
        XCTAssertFalse(policy.servicesDiscovered())
    }

    func testServiceChangeDuringInitialCharacteristicsCanRepairWithoutCancel() {
        var policy = BLEGATTRecoveryPolicy()
        policy.beginConnection()
        XCTAssertTrue(policy.servicesDiscovered())
        // iOS invalidates the selected service before its characteristics
        // complete. An old-characteristics callback cannot advance repair.
        XCTAssertTrue(policy.beginServiceRediscovery())
        XCTAssertFalse(policy.characteristicsDiscovered())
        XCTAssertFalse(policy.beginServiceRediscovery())
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), true)
        XCTAssertFalse(policy.beginServiceRediscovery())
    }

    func testServiceChangeDuringSubscriptionRepairPreservesSingleReadyBoundary() {
        var policy = readyPolicy()
        policy.notificationLost()
        XCTAssertTrue(policy.retryNotification("A", permitted: true))
        XCTAssertTrue(policy.beginServiceRediscovery())
        // A callback from the invalidated subscription cannot complete setup.
        XCTAssertNil(policy.notificationsReady())
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), false)
        XCTAssertTrue(policy.everReady)
        XCTAssertFalse(policy.beginServiceRediscovery())
    }

    func testInitialSubscriptionsCanBeInvalidatedBeforeFirstReady() {
        var policy = BLEGATTRecoveryPolicy()
        policy.beginConnection()
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertTrue(policy.beginServiceRediscovery())
        XCTAssertNil(policy.notificationsReady())
        XCTAssertTrue(policy.servicesDiscovered())
        XCTAssertTrue(policy.characteristicsDiscovered())
        XCTAssertEqual(policy.notificationsReady(), true)
    }

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

    func testSecondChannelLossWhileFirstRetryPendingIsRememberedAndSerialized() {
        let channels = ["A", "B", "C"]
        var policy = readyPolicy()
        var queue = BLENotificationQueue()
        queue.reset(restored: Set(channels))

        queue.received("A", notifying: false)
        policy.notificationLost()
        XCTAssertEqual(policy.phase, .subscribing)
        XCTAssertEqual(queue.next(in: channels), BLENotificationQueue.Request(identifier: "A", retry: true))
        XCTAssertTrue(policy.retryNotification("A", permitted: true))
        queue.requested("A")

        // B's asynchronous loss must not be dropped by A's pending request.
        queue.received("B", notifying: false)
        XCTAssertEqual(queue.confirmed, ["C"])
        XCTAssertEqual(queue.pending, "A")
        XCTAssertNil(queue.next(in: channels))

        queue.received("A", notifying: true)
        XCTAssertEqual(queue.next(in: channels), BLENotificationQueue.Request(identifier: "B", retry: true))
        XCTAssertTrue(policy.retryNotification("B", permitted: true))
        queue.requested("B")
        queue.received("B", notifying: true)
        XCTAssertEqual(queue.confirmed, Set(channels))
        XCTAssertNil(queue.next(in: channels))
        XCTAssertEqual(policy.notificationsReady(), false)
        // No new ride boundary or reset of either channel's retry budget.
        XCTAssertFalse(policy.retryNotification("A", permitted: true))
        XCTAssertFalse(policy.retryNotification("B", permitted: true))
    }

    func testProfileQueueWaitsForNotificationRepairThenCanContinue() {
        var policy = readyPolicy()
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: true, ready: true), .send)
        policy.notificationLost()
        // finishRequest can call sendNext in this state; production must retain
        // the rest of its profile rather than discard it with diagnosticRunning set.
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: true, ready: false),
                       .waitForSubscriptions)
        XCTAssertTrue(policy.retryNotification("A", permitted: true))
        XCTAssertEqual(policy.notificationsReady(), false)
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: true, ready: true), .send)
    }

    func testOnlySubscriptionRepairCanRetainQueuedCommands() {
        var policy = readyPolicy()
        policy.notificationLost()
        XCTAssertEqual(policy.commandDisposition(linkConnected: false, hasControl: true, ready: false), .discard)
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: false, ready: false), .discard)
        policy.markUnavailable()
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: true, ready: false), .discard)
        policy.beginConnection()
        XCTAssertEqual(policy.commandDisposition(linkConnected: true, hasControl: true, ready: false), .discard)
    }

    func testOtherChannelSuccessDoesNotReleasePendingSubscription() {
        var queue = BLENotificationQueue()
        let channels = ["A", "B", "C"]
        XCTAssertEqual(queue.next(in: channels), BLENotificationQueue.Request(identifier: "A", retry: false))
        queue.requested("A")
        queue.received("B", notifying: true)
        XCTAssertEqual(queue.pending, "A")
        XCTAssertNil(queue.next(in: channels))
        queue.received("A", notifying: true)
        XCTAssertEqual(queue.next(in: channels), BLENotificationQueue.Request(identifier: "C", retry: false))
    }

    func testFailedChannelRetryKeepsItsMissingStateAndBudgetExhausted() {
        var policy = readyPolicy()
        var queue = BLENotificationQueue()
        queue.reset(restored: ["A", "B", "C"])
        queue.received("A", notifying: false)
        policy.notificationLost()
        XCTAssertTrue(policy.retryNotification("A", permitted: true))
        queue.requested("A")
        queue.received("A", notifying: false)
        XCTAssertEqual(queue.next(in: ["A", "B", "C"]), BLENotificationQueue.Request(identifier: "A", retry: true))
        XCTAssertFalse(policy.retryNotification("A", permitted: true))
        XCTAssertFalse(queue.confirmed.contains("A"))
        queue.reset()
        XCTAssertEqual(queue.next(in: ["A", "B", "C"]), BLENotificationQueue.Request(identifier: "A", retry: false))
    }
}
