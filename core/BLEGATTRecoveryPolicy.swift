import Foundation

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

    mutating func beginConnection() {
        self = Self()
        phase = .discoveringServices
    }

    /// One rediscovery per established ACL. Another Service Changed callback
    /// is diagnostic evidence, but cannot start overlapping GATT operations.
    mutating func beginServiceRediscovery() -> Bool {
        guard phase == .ready, !serviceRediscoveryUsed else { return false }
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
