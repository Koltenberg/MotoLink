import Foundation

/// User-authorized transition from two independent legacy switches to one
/// automatic bike assistant. Finish remains attached to its physical connection;
/// Pause now applies only until the next application process starts.
enum AutomaticRideSettings {
    static let migrationKey = "MotoLink.automaticCapturePolicyVersion"

    @discardableResult static func migrate(_ defaults: UserDefaults) -> Bool {
        guard defaults.integer(forKey: migrationKey) < 1 else { return false }
        defaults.set(true, forKey: "MotoLink.autoReconnect")
        defaults.set(true, forKey: "MotoLink.autoRecord")
        defaults.set(false, forKey: "MotoLink.connectionPaused")
        defaults.set(1, forKey: migrationKey)
        return true
    }

    /// Run once while creating the Bluetooth owner, never on foreground or a
    /// radio state callback. An explicit pause survives all events in this
    /// process; a new launch resumes the selected bike without a hidden OFF.
    static func prepareForLaunch(_ defaults: UserDefaults) {
        migrate(defaults)
        defaults.set(false, forKey: "MotoLink.connectionPaused")
    }
}

/// Persist the rider's Finish action before asynchronous route recovery or disk
/// saving. A crash before the finished JSONL line must not resume the same ride.
struct RideFinishIntent {
    static let key = "MotoLink.pendingRideFinish"
    let rideID: UUID
    let requestedAt: Date

    init(rideID: UUID, requestedAt: Date) {
        self.rideID = rideID
        self.requestedAt = requestedAt
    }

    static func load(_ defaults: UserDefaults) -> RideFinishIntent? {
        decode(defaults.object(forKey: key))
    }

    static func decode(_ value: Any?) -> RideFinishIntent? {
        guard let saved = value as? [String: Any],
              let identifier = saved["rideID"] as? String,
              let rideID = UUID(uuidString: identifier),
              let requestedAt = saved["requestedAt"] as? Date,
              requestedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return RideFinishIntent(rideID: rideID, requestedAt: requestedAt)
    }

    func save(_ defaults: UserDefaults) {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else { return }
        let saved: [String: Any] = ["rideID": rideID.uuidString, "requestedAt": requestedAt]
        defaults.set(saved, forKey: Self.key)
    }

    static func clear(for rideID: UUID, in defaults: UserDefaults) {
        guard load(defaults)?.rideID == rideID else { return }
        defaults.removeObject(forKey: key)
    }

    func endedAt(startedAt: Date, now: Date) -> Date {
        // Preserve the original button press, not a later recovery time. Clock
        // changes cannot create a negative or future ride duration.
        let request = requestedAt.timeIntervalSinceReferenceDate.isFinite ? requestedAt : now
        return max(startedAt, min(request, now))
    }
}

/// Starting a ride depends on confirmed BLE channels, never on GPS permission.
/// A disconnect cannot establish engine shutdown, so this policy never ends rides.
struct RideAutomationPolicy {
    private(set) var channelsReady = false
    private(set) var peripheralID: UUID?
    private(set) var stoppedPeripheralID: UUID?

    init(stoppedPeripheralID: UUID? = nil) {
        self.stoppedPeripheralID = stoppedPeripheralID
    }

    var suppressedForConnection: Bool {
        peripheralID != nil && peripheralID == stoppedPeripheralID
    }

    mutating func observePeripheral(_ identifier: UUID) {
        channelsReady = false
        peripheralID = identifier
    }

    mutating func channelsBecameReady() { channelsReady = true }

    /// The initial published false value and a powered-off radio are not proof
    /// that an already-connected, restored peripheral ended its old session.
    mutating func transportDisconnected() {
        channelsReady = false
    }

    /// Only a validated didConnect/didDisconnect callback establishes a boundary.
    mutating func confirmedTransportBoundary(for identifier: UUID) {
        if stoppedPeripheralID == identifier { stoppedPeripheralID = nil }
        if peripheralID == identifier { channelsReady = false }
    }

    mutating func userRequestedManualStart() { stoppedPeripheralID = nil }

    /// Persist this at the start of saving, so a process death cannot undo Finish.
    mutating func userRequestedFinish(transportConnected: Bool) {
        if transportConnected, let peripheralID {
            stoppedPeripheralID = peripheralID
        } else if stoppedPeripheralID == peripheralID {
            stoppedPeripheralID = nil
        }
    }

    func shouldStart(enabled: Bool, hasActiveRide: Bool, finishing: Bool) -> Bool {
        enabled && peripheralID != nil && channelsReady && !hasActiveRide && !finishing && !suppressedForConnection
    }
}
