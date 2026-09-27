import Foundation

/// Starting a ride depends on confirmed BLE channels, never on GPS permission.
/// A disconnect cannot establish engine shutdown, so this policy never ends rides.
struct RideAutomationPolicy {
    private(set) var channelsReady = false
    private(set) var suppressedForConnection = false

    mutating func channelsBecameReady() { channelsReady = true }

    mutating func transportDisconnected() {
        channelsReady = false
        suppressedForConnection = false
    }

    mutating func userEnabledAutomaticRecording() { suppressedForConnection = false }

    mutating func rideFinished(transportConnected: Bool) {
        suppressedForConnection = transportConnected
    }

    func shouldStart(enabled: Bool, hasActiveRide: Bool, finishing: Bool) -> Bool {
        enabled && channelsReady && !hasActiveRide && !finishing && !suppressedForConnection
    }
}
