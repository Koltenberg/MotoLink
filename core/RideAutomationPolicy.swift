import Foundation

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

    mutating func userEnabledAutomaticRecording() { stoppedPeripheralID = nil }
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
