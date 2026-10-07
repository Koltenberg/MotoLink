import Foundation
import XCTest
@testable import MotoLinkCore

final class RideAutomationPolicyTests: XCTestCase {
    private let bikeA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let bikeB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func testFinishIntentSurvivesAProcessRestartBeforeJournalSaveAndClearsOnlyItsRide() {
        let suite = "MotoLink-FinishIntent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let rideID = UUID()
        let requestedAt = Date(timeIntervalSince1970: 10_000)
        RideFinishIntent(rideID: rideID, requestedAt: requestedAt).save(defaults)
        let restored = RideFinishIntent.load(defaults)
        XCTAssertEqual(restored?.rideID, rideID)
        XCTAssertEqual(restored?.requestedAt, requestedAt)
        RideFinishIntent.clear(for: UUID(), in: defaults)
        XCTAssertEqual(RideFinishIntent.load(defaults)?.rideID, rideID)
        RideFinishIntent.clear(for: rideID, in: defaults)
        XCTAssertNil(RideFinishIntent.load(defaults))
    }

    func testFinishIntentUsesButtonTimeRatherThanDelayedRestorationTime() {
        let start = Date(timeIntervalSince1970: 10_000)
        let pressed = start.addingTimeInterval(60)
        let recovered = start.addingTimeInterval(600)
        let intent = RideFinishIntent(rideID: UUID(), requestedAt: pressed)
        XCTAssertEqual(intent.endedAt(startedAt: start, now: recovered), pressed)
        let future = RideFinishIntent(rideID: UUID(), requestedAt: recovered.addingTimeInterval(10_000))
        XCTAssertEqual(future.endedAt(startedAt: start, now: recovered), recovered)
        let old = RideFinishIntent(rideID: UUID(), requestedAt: start.addingTimeInterval(-100))
        XCTAssertEqual(old.endedAt(startedAt: start, now: recovered), start)
    }

    func testMalformedFinishIntentCannotSelectAnotherRideOrNonfiniteBoundary() {
        XCTAssertNil(RideFinishIntent.decode(nil))
        XCTAssertNil(RideFinishIntent.decode("invalid"))
        XCTAssertNil(RideFinishIntent.decode(["rideID": "invalid", "requestedAt": Date()]))
        XCTAssertNil(RideFinishIntent.decode(["rideID": UUID().uuidString, "requestedAt": "tomorrow"]))
        XCTAssertNil(RideFinishIntent.decode(["rideID": UUID().uuidString,
            "requestedAt": Date(timeIntervalSinceReferenceDate: .infinity)]))
        XCTAssertNil(RideFinishIntent.decode(["rideID": UUID().uuidString,
            "requestedAt": Date(timeIntervalSinceReferenceDate: .nan)]))
    }

    func testMigrationPreservesExplicitLegacyOffSettingsAndFinishMarker() {
        let suite = "MotoLink-AutomaticMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "MotoLink.autoReconnect")
        defaults.set(false, forKey: "MotoLink.autoRecord")
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        defaults.set(bikeA.uuidString, forKey: "MotoLink.autoRecordFinishedPeripheral")
        XCTAssertTrue(AutomaticRideSettings.migrate(defaults))
        XCTAssertFalse(AutomaticRideSettings.autoReconnect(defaults))
        XCTAssertFalse(AutomaticRideSettings.autoRecord(defaults))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertEqual(defaults.integer(forKey: AutomaticRideSettings.migrationKey), 2)
        XCTAssertEqual(defaults.string(forKey: "MotoLink.autoRecordFinishedPeripheral"), bikeA.uuidString)
        // A later explicit pause is not another old-toggle accident.
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        XCTAssertFalse(AutomaticRideSettings.migrate(defaults))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertEqual(defaults.string(forKey: "MotoLink.autoRecordFinishedPeripheral"), bikeA.uuidString)
    }

    func testForcedOnVersionMigratesToOptionalDetailedRecordingOnlyOnce() {
        let suite = "MotoLink-PreferenceV2-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: AutomaticRideSettings.migrationKey)
        defaults.set(false, forKey: AutomaticRideSettings.autoReconnectKey)
        defaults.set(true, forKey: AutomaticRideSettings.autoRecordKey)
        XCTAssertTrue(AutomaticRideSettings.migrate(defaults))
        XCTAssertFalse(AutomaticRideSettings.autoReconnect(defaults))
        XCTAssertFalse(AutomaticRideSettings.autoRecord(defaults))
        // A subsequent explicit choice survives all recorder/owner launches.
        defaults.set(true, forKey: AutomaticRideSettings.autoRecordKey)
        AutomaticRideSettings.prepareForLaunch(defaults)
        XCTAssertFalse(AutomaticRideSettings.migrate(defaults))
        XCTAssertFalse(AutomaticRideSettings.autoReconnect(defaults))
        XCTAssertTrue(AutomaticRideSettings.autoRecord(defaults))
    }

    func testMissingPreferencesDefaultToConnectionWithoutDetailedRecording() {
        let suite = "MotoLink-NewPreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomaticRideSettings.prepareForLaunch(defaults)
        XCTAssertTrue(AutomaticRideSettings.autoReconnect(defaults))
        XCTAssertFalse(AutomaticRideSettings.autoRecord(defaults))
        defaults.set(false, forKey: AutomaticRideSettings.autoReconnectKey)
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        AutomaticRideSettings.prepareForLaunch(defaults)
        XCTAssertFalse(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertFalse(AutomaticRideSettings.autoReconnect(defaults))
    }

    func testOlderExplicitRecordingOnPreferenceIsNotMistakenForForcedOnRelease() {
        let suite = "MotoLink-LegacyPreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AutomaticRideSettings.autoRecordKey)
        AutomaticRideSettings.prepareForLaunch(defaults)
        XCTAssertTrue(AutomaticRideSettings.autoRecord(defaults))
    }

    func testDisablingReconnectCancelsAutomaticWaitWithoutRevokingManualConnectOrLiveLink() {
        XCTAssertTrue(AutomaticConnectionPreferencePolicy.shouldCancelPendingOnDisable(
            isConnected: false, manuallyRequested: false))
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldCancelPendingOnDisable(
            isConnected: false, manuallyRequested: true))
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldCancelPendingOnDisable(
            isConnected: true, manuallyRequested: false))
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldCancelPendingOnDisable(
            isConnected: true, manuallyRequested: true))
    }

    func testAutoOnThenOffCannotDemoteManualConnectQueuedBehindCancelAcknowledgement() {
        var manual = AutomaticConnectionPreferencePolicy.queuedRequestIsManual(
            existingManualRequest: false, newRequestIsManual: false)
        XCTAssertFalse(manual) // Automatic resume only.
        manual = AutomaticConnectionPreferencePolicy.queuedRequestIsManual(
            existingManualRequest: manual, newRequestIsManual: true)
        XCTAssertTrue(manual) // Rider explicitly Connects before cancel ACK.
        manual = AutomaticConnectionPreferencePolicy.queuedRequestIsManual(
            existingManualRequest: manual, newRequestIsManual: false)
        XCTAssertTrue(manual) // Turning automation ON does not replace that intent.
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldCancelPendingOnDisable(
            isConnected: false, manuallyRequested: manual))
        // A fulfilled or explicitly paused request is no longer pending/manual.
        manual = false
        XCTAssertTrue(AutomaticConnectionPreferencePolicy.shouldCancelPendingOnDisable(
            isConnected: false, manuallyRequested: manual))
    }

    func testSavedOffRejectsRestoredPendingRequestButPreservesExistingLink() {
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldAdoptRestoredPeripheral(
            enabled: false, isSaved: true, paused: false, isConnected: false))
        XCTAssertTrue(AutomaticConnectionPreferencePolicy.shouldAdoptRestoredPeripheral(
            enabled: false, isSaved: true, paused: false, isConnected: true))
        XCTAssertTrue(AutomaticConnectionPreferencePolicy.shouldAdoptRestoredPeripheral(
            enabled: true, isSaved: true, paused: false, isConnected: false))
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldAdoptRestoredPeripheral(
            enabled: true, isSaved: true, paused: true, isConnected: true))
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.shouldAdoptRestoredPeripheral(
            enabled: true, isSaved: false, paused: false, isConnected: true))
    }

    func testSavedOffPreventsNativeRecoveryAfterManualLinkDrops() {
        XCTAssertFalse(AutomaticConnectionPreferencePolicy.mayPreserveNativeReconnect(
            enabled: false, isConnected: false))
        XCTAssertTrue(AutomaticConnectionPreferencePolicy.mayPreserveNativeReconnect(
            enabled: false, isConnected: true))
        XCTAssertTrue(AutomaticConnectionPreferencePolicy.mayPreserveNativeReconnect(
            enabled: true, isConnected: false))
        // The current iOS request may have been created with auto-reconnect ON
        // before the rider turns it OFF. Its future native retry must cancel.
        var native = BLENativeReconnectPolicy()
        XCTAssertTrue(native.connectionRequested(for: bikeA, supported: true, enabled: true))
        XCTAssertTrue(native.connected(bikeA))
        let mayResume = AutomaticConnectionPreferencePolicy.mayPreserveNativeReconnect(
            enabled: false, isConnected: false)
        XCTAssertEqual(native.disconnected(bikeA, timestamp: 100, reconnecting: true,
            peripheralIsConnected: false, mayResume: mayResume), .cancelConnection)
        // A manual link still starts its normal data profile with both
        // preferences off; recording a trip is a separate decision.
        XCTAssertTrue(BLECaptureStartupPolicy.shouldRequest(ready: true,
            startedInSession: false, awaitingLateStream: false))
        XCTAssertFalse(readyPolicy().shouldStart(enabled: false, hasActiveRide: false, finishing: false))
    }

    func testAutomaticProductModeStillRequiresAnIdentifiedReadyMotorcycle() {
        var policy = RideAutomationPolicy()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.observePeripheral(bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.userRequestedFinish(transportConnected: true)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testNewApplicationProcessResumesPausedBikeWithoutErasingFinishedRideMarker() {
        let suite = "MotoLink-AutomaticLaunch-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        AutomaticRideSettings.prepareForLaunch(defaults)
        defaults.set(true, forKey: "MotoLink.connectionPaused")
        defaults.set(bikeA.uuidString, forKey: "MotoLink.autoRecordFinishedPeripheral")
        // The recorder may inspect migration again; this is not a new process.
        XCTAssertFalse(AutomaticRideSettings.migrate(defaults))
        XCTAssertTrue(defaults.bool(forKey: "MotoLink.connectionPaused"))
        // Only creating the Bluetooth owner for a new process resumes intent.
        AutomaticRideSettings.prepareForLaunch(defaults)
        XCTAssertFalse(defaults.bool(forKey: "MotoLink.connectionPaused"))
        XCTAssertEqual(defaults.string(forKey: "MotoLink.autoRecordFinishedPeripheral"), bikeA.uuidString)
        var restored = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        restored.observePeripheral(bikeA)
        restored.channelsBecameReady()
        XCTAssertFalse(restored.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testInPlaceRepairRestoresReadinessWithoutOverridingRecordingChoice() {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
        // Same-link service discovery observes identity again. Its ready
        // callback must reach the recorder even though this is not firstReady.
        policy.observePeripheral(bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testRepeatedReadinessAfterRepairDoesNotUndoManualFinish() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        XCTAssertEqual(policy.stoppedPeripheralID, bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    private func readyPolicy() -> RideAutomationPolicy {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        return policy
    }

    func testBluetoothTransportAloneDoesNotStartCapture() {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReadyChannelsNeedIdentifiedMotorcycle() {
        var policy = RideAutomationPolicy()
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReadyChannelsStartWithoutAnyGPSDependency() {
        let policy = readyPolicy()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        XCTAssertFalse(policy.shouldStart(enabled: false, hasActiveRide: false, finishing: false))
    }

    func testReconnectKeepsExistingRideRatherThanStartingAnother() {
        var policy = readyPolicy()
        policy.confirmedTransportBoundary(for: bikeA)
        policy.transportDisconnected()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testRestoredRideIsNeverReplaced() {
        var restoredPolicy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        restoredPolicy.observePeripheral(bikeA)
        restoredPolicy.channelsBecameReady()
        XCTAssertFalse(restoredPolicy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        restoredPolicy.confirmedTransportBoundary(for: bikeA)
        restoredPolicy.channelsBecameReady()
        XCTAssertFalse(restoredPolicy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
    }

    func testAsynchronousSaveCannotStartAnotherRide() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: true))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: true))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testManualFinishSuppressesSameConnectionButNotNextConnection() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.confirmedTransportBoundary(for: bikeA)
        policy.transportDisconnected()
        XCTAssertNil(policy.stoppedPeripheralID)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testFinishWhileDisconnectedAllowsNextReadyConnection() {
        var policy = RideAutomationPolicy()
        policy.observePeripheral(bikeA)
        policy.userRequestedFinish(transportConnected: false)
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testSavedFinishSurvivesNewProcessAndRestoredConnectedPeripheral() {
        var beforeRestart = readyPolicy()
        beforeRestart.userRequestedFinish(transportConnected: true)
        let persistedID = beforeRestart.stoppedPeripheralID
        XCTAssertEqual(persistedID, bikeA)

        var afterRestart = RideAutomationPolicy(stoppedPeripheralID: persistedID)
        afterRestart.transportDisconnected() // Initial Published(false), not a BLE callback.
        afterRestart.observePeripheral(bikeA)
        afterRestart.channelsBecameReady() // Restoration has no new didConnect.
        XCTAssertEqual(afterRestart.stoppedPeripheralID, bikeA)
        XCTAssertFalse(afterRestart.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testConfirmedNewConnectionClearsRestoredFinishMarker() {
        var policy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        policy.observePeripheral(bikeA)
        policy.confirmedTransportBoundary(for: bikeA) // Actual didConnect.
        policy.channelsBecameReady()
        XCTAssertNil(policy.stoppedPeripheralID)
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testOtherMotorcycleDoesNotInheritFinishedSession() {
        var policy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        policy.observePeripheral(bikeB)
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.confirmedTransportBoundary(for: bikeB)
        XCTAssertEqual(policy.stoppedPeripheralID, bikeA)
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testChangingMotorcycleRequiresFreshChannelReadiness() {
        var policy = readyPolicy()
        policy.observePeripheral(bikeB)
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
        policy.channelsBecameReady()
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testExplicitManualStartClearsSavedFinishMarker() {
        var policy = RideAutomationPolicy(stoppedPeripheralID: bikeA)
        policy.observePeripheral(bikeA)
        policy.channelsBecameReady()
        policy.userRequestedManualStart()
        XCTAssertNil(policy.stoppedPeripheralID)
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }

    func testReconnectDuringSaveStartsOnlyAfterSavedRideIsReleased() {
        var policy = readyPolicy()
        policy.userRequestedFinish(transportConnected: true)
        policy.confirmedTransportBoundary(for: bikeA)
        policy.transportDisconnected()
        policy.confirmedTransportBoundary(for: bikeA)
        policy.channelsBecameReady()
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: true))
        XCTAssertFalse(policy.shouldStart(enabled: true, hasActiveRide: true, finishing: false))
        XCTAssertTrue(policy.shouldStart(enabled: true, hasActiveRide: false, finishing: false))
    }
}

final class RidePausePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    private func parked(at seconds: Double = 2_400) -> RidePausePolicy {
        var policy = RidePausePolicy()
        policy.recordActivity(at: at(seconds))
        policy.observeBikeSpeed(0, at: at(seconds))
        policy.transportDisconnected(at: at(seconds))
        return policy
    }

    func testSixMinuteTwentySecondStopIsRemovedFromClockWhileDatesRemainReal() {
        var policy = parked()
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(2_700)), 2_400)
        policy.streamReturned(at: at(2_780))
        XCTAssertNil(policy.pausedAt)
        XCTAssertNil(policy.disconnectedAt)
        XCTAssertEqual(policy.excluded.count, 1)
        XCTAssertEqual(policy.excluded.first?.startedAt, at(2_400))
        XCTAssertEqual(policy.excluded.first?.endedAt, at(2_780))
        XCTAssertEqual(policy.excluded.first?.kind, .parking)
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(2_780)), 2_400)
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(2_840)), 2_460)
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(2_000)), 2_000)
        XCTAssertEqual(policy.recordedSeconds(from: at(2_500), to: at(2_800)), 20)
    }

    func testFifteenMinuteDeadlineReturnsTheStopTimeNotTheWakeTime() {
        var policy = parked(at: 3_000)
        XCTAssertNil(policy.expiredStop(at: at(3_899.999)))
        XCTAssertEqual(policy.expiredStop(at: at(3_900)), at(3_000))
        XCTAssertEqual(policy.expiredStop(at: at(30_000)), at(3_000))
        policy.transportDisconnected(at: at(3_899))
        XCTAssertEqual(policy.expiredStop(at: at(3_900)), at(3_000))
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(3_900)), 3_000)
    }

    func testMovingBluetoothLossKeepsGPSTimeAndNeverEndsTheRide() {
        var policy = RidePausePolicy()
        policy.recordActivity(at: start)
        policy.observeBikeSpeed(20, at: start)
        policy.transportDisconnected(at: start)
        for second in stride(from: 5, through: 1_200, by: 5) {
            policy.observeGPSSpeed(20, at: at(Double(second)))
            policy.recordActivity(at: at(Double(second)))
        }
        XCTAssertNil(policy.pausedAt)
        XCTAssertNil(policy.expiredStop(at: at(1_200)))
        XCTAssertTrue(policy.excluded.isEmpty)
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(1_200)), 1_200)
    }

    func testStaleOrMissingBikeZeroCannotDeclareAStop() {
        var stale = RidePausePolicy()
        stale.observeBikeSpeed(0, at: start)
        stale.transportDisconnected(at: at(6))
        XCTAssertNil(stale.pausedAt)
        XCTAssertNil(stale.expiredStop(at: at(10_000)))
        var unknown = RidePausePolicy()
        unknown.transportDisconnected(at: start)
        XCTAssertNil(unknown.expiredStop(at: at(10_000)))
    }

    func testFreshMovingGPSOverridesZeroWheelReading() {
        var policy = RidePausePolicy()
        policy.observeBikeSpeed(0, at: start)
        policy.observeGPSSpeed(10, at: start)
        policy.transportDisconnected(at: at(1))
        XCTAssertNil(policy.pausedAt)
    }

    func testGPSConfirmsParkingOnlyAfterContinuousReliableStationarySamples() {
        var policy = RidePausePolicy()
        policy.transportDisconnected(at: start)
        policy.observeGPSSpeed(0, at: at(1))
        policy.observeGPSSpeed(0.2, at: at(4))
        XCTAssertNil(policy.pausedAt)
        policy.gpsUnavailable()
        policy.observeGPSSpeed(0, at: at(6))
        XCTAssertNil(policy.pausedAt)
        policy.observeGPSSpeed(0, at: at(11))
        XCTAssertEqual(policy.pausedAt, at(11))
        XCTAssertEqual(policy.expiredStop(at: at(911)), at(11))
    }

    func testSingleZeroAndLaterStaleZeroAreNotContinuousStopEvidence() {
        var policy = RidePausePolicy()
        policy.transportDisconnected(at: start)
        policy.observeGPSSpeed(0, at: at(1))
        policy.observeGPSSpeed(0, at: at(20))
        XCTAssertNil(policy.pausedAt)
        policy.observeGPSSpeed(1.5, at: at(23))
        policy.observeGPSSpeed(0, at: at(26))
        XCTAssertNil(policy.pausedAt)
    }

    func testGPSMovementResumesTheSameClockEvenBeforeBluetoothReturns() {
        var policy = parked(at: 60)
        policy.observeGPSSpeed(10, at: at(120))
        policy.recordActivity(at: at(120))
        XCTAssertNil(policy.pausedAt)
        XCTAssertNotNil(policy.disconnectedAt)
        XCTAssertNil(policy.expiredStop(at: at(10_000)))
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(150)), 90)
        policy.streamReturned(at: at(125))
        XCTAssertEqual(policy.excluded.count, 1)
    }

    func testWhollyMissingDataCompressesTimeButDoesNotPretendTheRouteWasStationary() {
        var policy = RidePausePolicy()
        policy.recordActivity(at: at(2_400))
        policy.observeBikeSpeed(20, at: at(2_400))
        policy.transportDisconnected(at: at(2_400))
        policy.streamReturned(at: at(2_780))
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(2_780)), 2_400)
        XCTAssertEqual(policy.excluded.first?.kind, .missingData)
        XCTAssertFalse(policy.containsParkingPause(between: at(2_400), and: at(2_780)))
        XCTAssertEqual(policy.nonParkingSeconds(from: at(2_400), to: at(2_780)), 380)
    }

    func testSeveralPausesAndUnknownGapAreNotSubtractedTwice() {
        var policy = parked(at: 60)
        policy.streamReturned(at: at(120))
        policy.recordActivity(at: at(210)) // 90 seconds without any observations
        policy.observeBikeSpeed(0, at: at(210))
        policy.transportDisconnected(at: at(210))
        policy.streamReturned(at: at(270))
        XCTAssertEqual(policy.excluded.map(\.kind), [.parking, .missingData, .parking])
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(300)), 90)
        XCTAssertEqual(policy.nonParkingSeconds(from: start, to: at(300)), 180)
    }

    func testSlowSensorRepliesDoNotShrinkAnOngoingRecording() {
        var policy = RidePausePolicy()
        for second in stride(from: 0, through: 300, by: 30) {
            policy.recordActivity(at: at(Double(second)))
        }
        XCTAssertTrue(policy.excluded.isEmpty)
        XCTAssertEqual(policy.recordedSeconds(from: start, to: at(300)), 300)
    }

    func testPauseAndDeadlineSurviveSerializationBeforeAndAfterResume() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var restored = try decoder.decode(RidePausePolicy.self, from: encoder.encode(parked()))
        XCTAssertEqual(restored.expiredStop(at: at(3_300)), at(2_400))
        restored.streamReturned(at: at(2_780))
        let again = try decoder.decode(RidePausePolicy.self, from: encoder.encode(restored))
        XCTAssertEqual(again, restored)
        XCTAssertEqual(again.recordedSeconds(from: start, to: at(2_840)), 2_460)
    }

    func testStaleOrInvalidCallbacksCannotResumeParkingOrResetItsDeadline() {
        var policy = parked(at: 60)
        let saved = policy
        policy.streamReturned(at: at(59))
        policy.streamReturned(at: Date(timeIntervalSince1970: .nan))
        policy.observeGPSSpeed(.nan, at: at(100))
        policy.observeGPSSpeed(101, at: at(100))
        policy.observeGPSSpeed(10, at: at(59))
        XCTAssertEqual(policy.pausedAt, saved.pausedAt)
        XCTAssertEqual(policy.expiredStop(at: at(960)), at(60))
        XCTAssertEqual(policy.recordedSeconds(from: at(100), to: at(99)), 0)
        XCTAssertEqual(policy.recordedSeconds(from: start, to: Date(timeIntervalSince1970: .infinity)), 0)
    }

    func testAutomaticFinishIntentAndLegacyManualIntentRemainDistinctAfterRestart() {
        let suite = "MotoLink-ParkingFinish-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        RideFinishIntent(rideID: id, requestedAt: at(60), automatic: true).save(defaults)
        XCTAssertEqual(RideFinishIntent.load(defaults)?.automatic, true)
        XCTAssertEqual(RideFinishIntent.load(defaults)?.endedAt(startedAt: start, now: at(2_000)), at(60))
        let legacy: [String: Any] = ["rideID": id.uuidString, "requestedAt": at(60)]
        XCTAssertEqual(RideFinishIntent.decode(legacy)?.automatic, false)
    }
}
