import Foundation

/// Live instruments are part of an established connection, independently of
/// whether the rider enabled future reconnects or is saving a ride. Keep the
/// same session and completed-write retry protections for every caller.
enum BLECaptureStartupPolicy {
    static func shouldRequest(ready: Bool, startedInSession: Bool,
                              awaitingLateStream: Bool) -> Bool {
        ready && !startedInSession && !awaitingLateStream
    }
}

/// Bounds repair of GATT objects while CoreBluetooth still owns a connected ACL.
/// This policy never requests a physical disconnect or a second BLE connection.
struct BLEGATTRecoveryPolicy {
    enum Phase: Equatable {
        case idle, discoveringServices, discoveringCharacteristics, subscribing, ready, unavailable
    }

    private(set) var phase: Phase = .idle
    private(set) var everReady = false
    private(set) var serviceRediscoveryUsed = false
    private var serviceDiscoveryRetryUsed = false
    private var characteristicDiscoveryRetryUsed = false
    private var notificationRetries: Set<String> = []

    enum CaptureContinuation: Equatable { case none, preserve, restart }

    /// Starting a profile is not evidence it completed. A notification failure
    /// can stop its queue before 08 while the ACL and other channels stay alive.
    /// After an explicit GATT repair, restart that interrupted profile; preserve
    /// a completed one without sending its setup commands again.
    static func captureContinuation(sameLink: Bool, startedInSession: Bool,
                                    running: Bool, requested: Bool,
                                    interrupted: Bool) -> CaptureContinuation {
        guard sameLink else { return .none }
        if running || requested || interrupted { return .restart }
        return startedInSession ? .preserve : .none
    }

    mutating func beginConnection() {
        self = Self()
        phase = .discoveringServices
    }

    /// A deadline without a CoreBluetooth completion is only an observation.
    /// It cannot release the outstanding operation: pairing or background
    /// delivery may delay the callback while the physical connection stays up.
    /// Keep the phase and let that original callback finish setup. Starting
    /// another request here would overlap ATT, and marking unavailable would
    /// permanently ignore a successful late callback.
    func pendingSetupAfterObservationTimeout(linkConnected: Bool) -> Phase? {
        guard linkConnected else { return nil }
        switch phase {
        case .discoveringServices, .discoveringCharacteristics, .subscribing: return phase
        case .idle, .ready, .unavailable: return nil
        }
    }

    /// One rediscovery per established ACL, only after the driver confirms that
    /// Service Changed invalidated its selected service. A completed notification
    /// failure may leave other channels alive in .unavailable; an explicit
    /// invalidation then gives us new GATT objects, not another retry of the old
    /// failed subscription. Keep that one repair available in this state too.
    mutating func beginServiceRediscovery() -> Bool {
        guard phase == .ready || phase == .discoveringCharacteristics || phase == .subscribing
                || phase == .unavailable,
              !serviceRediscoveryUsed else { return false }
        serviceRediscoveryUsed = true
        serviceDiscoveryRetryUsed = false
        characteristicDiscoveryRetryUsed = false
        notificationRetries.removeAll()
        phase = .discoveringServices
        return true
    }

    mutating func retryServices() -> Bool {
        guard phase == .discoveringServices, !serviceDiscoveryRetryUsed else { return false }
        serviceDiscoveryRetryUsed = true
        return true
    }

    mutating func retryCharacteristics() -> Bool {
        guard phase == .discoveringCharacteristics, !characteristicDiscoveryRetryUsed else { return false }
        characteristicDiscoveryRetryUsed = true
        return true
    }

    mutating func servicesDiscovered() -> Bool {
        guard phase == .discoveringServices else { return false }
        phase = .discoveringCharacteristics
        return true
    }

    mutating func characteristicsDiscovered() -> Bool {
        guard phase == .discoveringCharacteristics else { return false }
        phase = .subscribing
        return true
    }

    /// A second channel can stop while a different subscription is pending.
    /// Record the loss immediately, but spend its retry only when it is sent.
    mutating func notificationLost() {
        if phase == .ready { phase = .subscribing }
    }

    enum CommandDisposition: Equatable { case send, waitForSubscriptions, discard }

    func commandDisposition(linkConnected: Bool, hasControl: Bool, ready: Bool) -> CommandDisposition {
        guard linkConnected, hasControl else { return .discard }
        if ready { return .send }
        return phase == .subscribing ? .waitForSubscriptions : .discard
    }

    /// The callback for a failed setNotifyValue has completed, so retrying that
    /// same valid characteristic once cannot overlap the original request.
    mutating func retryNotification(_ identifier: String, permitted: Bool) -> Bool {
        guard phase == .subscribing || phase == .ready else { return false }
        phase = .subscribing
        guard permitted, notificationRetries.insert(identifier).inserted else { return false }
        return true
    }

    /// Returns whether this is the first readiness on the physical connection.
    /// A repaired subscription should not create another ride boundary.
    mutating func notificationsReady() -> Bool? {
        guard phase == .subscribing else { return nil }
        let first = !everReady
        everReady = true
        phase = .ready
        return first
    }

    mutating func markUnavailable() { phase = .unavailable }
}

/// Bookkeeping for the three independent notification channels. A callback
/// from one channel must not disappear just because another channel is pending.
struct BLENotificationQueue {
    struct Request: Equatable {
        let identifier: String
        let retry: Bool
    }

    private(set) var confirmed: Set<String> = []
    private(set) var pending: String?
    private var retryNeeded: Set<String> = []

    mutating func reset(restored: Set<String> = []) {
        confirmed = restored
        pending = nil
        retryNeeded.removeAll()
    }

    mutating func received(_ identifier: String, notifying: Bool) {
        if pending == identifier { pending = nil }
        if notifying {
            confirmed.insert(identifier)
            retryNeeded.remove(identifier)
        } else {
            confirmed.remove(identifier)
            retryNeeded.insert(identifier)
        }
    }

    func next(in identifiers: [String]) -> Request? {
        guard pending == nil,
              let identifier = identifiers.first(where: { !confirmed.contains($0) }) else { return nil }
        return Request(identifier: identifier, retry: retryNeeded.contains(identifier))
    }

    mutating func requested(_ identifier: String) { pending = identifier }
    mutating func stopWaiting() { pending = nil }
}
