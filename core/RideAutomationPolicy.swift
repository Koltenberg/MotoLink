import Foundation

/// Persistent choices for automatic connection and detailed trip recording.
/// Version 1 forced both on; version 2 restores independent rider control.
enum AutomaticRideSettings {
    static let migrationKey = "MotoLink.automaticCapturePolicyVersion"
    static let autoReconnectKey = "MotoLink.autoReconnect"
    static let autoRecordKey = "MotoLink.autoRecord"

    @discardableResult static func migrate(_ defaults: UserDefaults) -> Bool {
        let previous = defaults.integer(forKey: migrationKey)
        guard previous < 2 else { return false }
        if defaults.object(forKey: autoReconnectKey) == nil {
            defaults.set(true, forKey: autoReconnectKey)
        }
        // The forced-on release did not express a choice to retain every trip.
        // Reset that release once, while preserving explicit older preferences.
        if previous == 1 || defaults.object(forKey: autoRecordKey) == nil {
            defaults.set(false, forKey: autoRecordKey)
        }
        defaults.set(2, forKey: migrationKey)
        return true
    }

    static func autoReconnect(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: autoReconnectKey) == nil ? true : defaults.bool(forKey: autoReconnectKey)
    }

    static func autoRecord(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: autoRecordKey)
    }

    /// Run once while creating the Bluetooth owner, never on foreground or a
    /// radio state callback. A temporary pause expires, but the saved OFF
    /// preference continues to prohibit automatic requests on the next launch.
    static func prepareForLaunch(_ defaults: UserDefaults) {
        migrate(defaults)
        defaults.set(false, forKey: "MotoLink.connectionPaused")
    }
}

/// Turning off future reconnection must not tear down live telemetry or revoke
/// a separate, explicit Connect action which is still waiting for the bike.
enum AutomaticConnectionPreferencePolicy {
    static func queuedRequestIsManual(existingManualRequest: Bool, newRequestIsManual: Bool) -> Bool {
        // Enabling automation while an explicit Connect waits for a cancel ACK
        // cannot demote that separate user intent into an automatic attempt.
        existingManualRequest || newRequestIsManual
    }

    static func shouldCancelPendingOnDisable(isConnected: Bool, manuallyRequested: Bool) -> Bool {
        !isConnected && !manuallyRequested
    }

    static func shouldAdoptRestoredPeripheral(enabled: Bool, isSaved: Bool,
                                              paused: Bool, isConnected: Bool) -> Bool {
        isSaved && !paused && (enabled || isConnected)
    }

    static func mayPreserveNativeReconnect(enabled: Bool, isConnected: Bool) -> Bool {
        // A delayed disconnect may observe a link which is already connected.
        // Preserve that real link; OFF forbids an outstanding future attempt.
        enabled || isConnected
    }
}

/// Persist the rider's Finish action before asynchronous route recovery or disk
/// saving. A crash before the finished JSONL line must not resume the same ride.
struct RideFinishIntent {
    static let key = "MotoLink.pendingRideFinish"
    let rideID: UUID
    let requestedAt: Date
    let automatic: Bool

    init(rideID: UUID, requestedAt: Date, automatic: Bool = false) {
        self.rideID = rideID
        self.requestedAt = requestedAt
        self.automatic = automatic
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
        return RideFinishIntent(rideID: rideID, requestedAt: requestedAt,
                                automatic: saved["automatic"] as? Bool ?? false)
    }

    func save(_ defaults: UserDefaults) {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else { return }
        let saved: [String: Any] = ["rideID": rideID.uuidString, "requestedAt": requestedAt, "automatic": automatic]
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

/// The raw observations keep their real timestamps. Only the presentation's
/// recording clock excludes these disjoint intervals; distance is never guessed.
struct RidePauseInterval: Codable, Equatable {
    enum Kind: String, Codable { case parking, missingData }
    var startedAt: Date
    var endedAt: Date
    var kind: Kind
}

/// A stopped bike plus lost transport can start a parking pause. A moving bike
/// losing Bluetooth alone cannot. GPS may confirm a subsequent stop, or cancel
/// a false stationary assumption. Timers only wake this policy: the deadline is
/// persisted and evaluated on callbacks/foreground/relaunch as well.
struct RidePausePolicy: Codable, Equatable {
    static let timeout: TimeInterval = 15 * 60
    // Slow ECU replies and coalesced background fixes can legitimately be
    // tens of seconds apart. Short confirmed parking pauses are excluded
    // immediately, but an unknown all-source silence needs at least a minute.
    static let missingDataInterval: TimeInterval = 60
    private struct Speed: Codable, Equatable { let value: Double; let date: Date }
    private var bikeSpeed: Speed?
    private var gpsSpeed: Speed?
    private var stationarySince: Date?
    private(set) var disconnectedAt: Date?
    private(set) var pausedAt: Date?
    private(set) var lastActivityAt: Date?
    private(set) var excluded: [RidePauseInterval] = []

    mutating func observeBikeSpeed(_ speed: Double, at date: Date) {
        guard valid(speed, date), bikeSpeed == nil || date > bikeSpeed!.date else { return }
        bikeSpeed = Speed(value: speed, date: date)
    }

    mutating func transportDisconnected(at date: Date) {
        guard date.timeIntervalSince1970.isFinite, disconnectedAt == nil else { return }
        disconnectedAt = date
        stationarySince = nil
        let movingGPS = gpsSpeed.map { (0...5).contains(date.timeIntervalSince($0.date)) && $0.value >= 2.5 } ?? false
        if let bikeSpeed, (0...5).contains(date.timeIntervalSince(bikeSpeed.date)),
           bikeSpeed.value <= 0.5, !movingGPS {
            pausedAt = date
        }
    }

    /// Feed only accepted, fresh GPS speeds. Poor/absent GPS cannot establish
    /// that a motorcycle has stopped and cannot finish a moving ride.
    mutating func observeGPSSpeed(_ speed: Double, at date: Date) {
        guard valid(speed, date), gpsSpeed == nil || date > gpsSpeed!.date else { return }
        let previous = gpsSpeed
        gpsSpeed = Speed(value: speed, date: date)
        guard let disconnectedAt, date >= disconnectedAt else { return }
        if speed >= 2.5 {
            closePause(at: date)
            stationarySince = nil
        } else if speed <= 1 {
            if stationarySince == nil || previous == nil || date.timeIntervalSince(previous!.date) > 10 {
                stationarySince = date
            }
            if pausedAt == nil, let stationarySince, date.timeIntervalSince(stationarySince) >= 5 {
                // Use the confirmation boundary, not an earlier timestamp
                // whose already-written measurements would require deletion.
                pausedAt = date
            }
        } else { stationarySince = nil }
    }

    mutating func gpsUnavailable() { stationarySince = nil }

    /// Real telemetry resumes the ride, not merely a lit Bluetooth icon.
    /// The caller checks expiration before this, so a late reconnect cannot
    /// merge a new journey into an already expired parking pause.
    mutating func streamReturned(at date: Date) {
        guard date.timeIntervalSince1970.isFinite, pausedAt == nil || date >= pausedAt!,
              disconnectedAt == nil || date >= disconnectedAt! else { return }
        closePause(at: date)
        disconnectedAt = nil
        stationarySince = nil
        recordActivity(at: date)
    }

    /// If neither GPS nor motorcycle data existed for a long interval, compress
    /// that empty interval on the recording timeline. Valid GPS through a BLE
    /// outage keeps advancing this cursor and therefore remains fully visible.
    mutating func recordActivity(at date: Date) {
        guard date.timeIntervalSince1970.isFinite, pausedAt == nil,
              lastActivityAt == nil || date > lastActivityAt! else { return }
        if let lastActivityAt, date.timeIntervalSince(lastActivityAt) > Self.missingDataInterval {
            exclude(from: lastActivityAt, to: date, kind: .missingData)
        }
        lastActivityAt = date
    }

    func expiredStop(at date: Date) -> Date? {
        guard let pausedAt, date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince(pausedAt) >= Self.timeout else { return nil }
        return pausedAt
    }

    func recordedSeconds(from start: Date, to end: Date) -> TimeInterval {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start else { return 0 }
        let effectiveEnd = min(end, pausedAt ?? end)
        guard effectiveEnd > start else { return 0 }
        let removed = excluded.reduce(0.0) { sum, interval in
            sum + max(0, min(effectiveEnd, interval.endedAt).timeIntervalSince(max(start, interval.startedAt)))
        }
        return max(0, effectiveEnd.timeIntervalSince(start) - removed)
    }

    func containsParkingPause(between start: Date, and end: Date) -> Bool {
        excluded.contains { $0.kind == .parking && $0.startedAt < end && $0.endedAt > start }
            || (pausedAt.map { $0 < end } ?? false)
    }

    /// Only confirmed parking can hide an otherwise empty route interval.
    /// A total loss of observations still needs a visible gap on the map even
    /// though its empty time is compressed in the graphs.
    func nonParkingSeconds(from start: Date, to end: Date) -> TimeInterval {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start else { return 0 }
        let effectiveEnd = min(end, pausedAt ?? end)
        guard effectiveEnd > start else { return 0 }
        let removed = excluded.filter { $0.kind == .parking }.reduce(0.0) { sum, interval in
            sum + max(0, min(effectiveEnd, interval.endedAt).timeIntervalSince(max(start, interval.startedAt)))
        }
        return max(0, effectiveEnd.timeIntervalSince(start) - removed)
    }

    private func valid(_ speed: Double, _ date: Date) -> Bool {
        speed.isFinite && (0...100).contains(speed) && date.timeIntervalSince1970.isFinite
    }

    private mutating func closePause(at date: Date) {
        guard let pausedAt, date >= pausedAt else { return }
        exclude(from: pausedAt, to: date, kind: .parking)
        self.pausedAt = nil
        // The interval has already been excluded; avoid a second missing-data
        // exclusion that overlaps it on the next real frame.
        lastActivityAt = date
    }

    private mutating func exclude(from start: Date, to end: Date, kind: RidePauseInterval.Kind) {
        guard end > start else { return }
        if let last = excluded.last, last.kind == kind, last.endedAt >= start {
            excluded[excluded.count - 1].endedAt = max(last.endedAt, end)
        } else {
            let orderedStart = max(start, excluded.last?.endedAt ?? start)
            if end > orderedStart {
                excluded.append(RidePauseInterval(startedAt: orderedStart, endedAt: end, kind: kind))
            }
        }
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
