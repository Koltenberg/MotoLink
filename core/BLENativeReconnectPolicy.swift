import Foundation

/// Ownership of a pending connect, separate from application retry deadlines.
/// This policy cannot change radio parameters or prevent a physical link loss.
struct BLENativeReconnectPolicy {
    enum DisconnectAction: Equatable {
        case ignore, waitForSystem, cancelConnection, prepareConnected, applicationFallback
    }

    private(set) var peripheralID: UUID?
    private(set) var systemOwnsPendingConnection = false
    private(set) var awaitingCancellation = false
    private(set) var optionUsedForAttempt = false
    private(set) var optionRejected = false
    private var connectsSinceBoundary = 0
    private var lastDisconnectTimestamp: TimeInterval?
    private var lastDisconnectWasReconnecting = false
    private var preparedBeforeDidConnect = false

    /// Returns the option for this request. A rejected optional parameter is
    /// disabled for this process; subsequent ordinary failures still back off.
    mutating func connectionRequested(for identifier: UUID, supported: Bool, enabled: Bool) -> Bool {
        clearConnection()
        peripheralID = identifier
        optionUsedForAttempt = supported && enabled && !optionRejected
        return optionUsedForAttempt
    }

    /// A restored pending request already belongs to iOS, regardless of which
    /// connect options the previous process used. Never issue a second one.
    mutating func restored(_ identifier: UUID, connecting: Bool) {
        clearConnection()
        peripheralID = identifier
        systemOwnsPendingConnection = connecting
    }

    /// False means a delayed didConnect follows a connection already prepared
    /// from an extended callback observing the peripheral as currently connected.
    mutating func connected(_ identifier: UUID) -> Bool {
        guard peripheralID == identifier, !awaitingCancellation else { return false }
        systemOwnsPendingConnection = false
        let needsPreparation = !preparedBeforeDidConnect
        if needsPreparation { connectsSinceBoundary += 1 }
        preparedBeforeDidConnect = false
        return needsPreparation
    }

    /// Restore/current-state reconciliation can prepare GATT before a queued
    /// didConnect. That callback must not run the capture profile a second time.
    mutating func preparedConnectedState(_ identifier: UUID) {
        guard peripheralID == identifier, !awaitingCancellation else { return }
        systemOwnsPendingConnection = false
        connectsSinceBoundary = 1
        preparedBeforeDidConnect = true
    }

    mutating func disconnected(_ identifier: UUID, timestamp: TimeInterval,
                              reconnecting: Bool,
                              peripheralIsConnected: Bool, mayResume: Bool) -> DisconnectAction {
        guard peripheralID == identifier else { return .ignore }
        let usableTimestamp = timestamp.isFinite && timestamp > 0
        // Treat the timestamp as an opaque event identifier. Do not compare it
        // to wall time/uptime or order different values: the callback's epoch is
        // not documented here, and a user can change the phone's clock.
        let newlyDisconnectedState = !peripheralIsConnected && connectsSinceBoundary > 0
        if usableTimestamp, timestamp == lastDisconnectTimestamp,
           reconnecting == lastDisconnectWasReconnecting,
           !newlyDisconnectedState,
           !awaitingCancellation || reconnecting { return .ignore }
        // Two actual didConnect callbacks without an intervening boundary mean
        // iOS already delivered a new connection before this delayed event.
        // Current .connected state is required; a queued callback alone is not
        // evidence that the link is still alive.
        let newerConnectAlreadyObserved = peripheralIsConnected
            && connectsSinceBoundary > 1 && !awaitingCancellation
        if usableTimestamp { lastDisconnectTimestamp = timestamp }
        lastDisconnectWasReconnecting = reconnecting
        if newerConnectAlreadyObserved && mayResume {
            connectsSinceBoundary = 1
            return .ignore
        }
        connectsSinceBoundary = 0
        preparedBeforeDidConnect = false
        systemOwnsPendingConnection = reconnecting
        if reconnecting && (!mayResume || awaitingCancellation) { return .cancelConnection }
        if peripheralIsConnected {
            guard mayResume, !awaitingCancellation else { return .cancelConnection }
            preparedConnectedState(identifier)
            return .prepareConnected
        }
        if reconnecting { return .waitForSystem }
        awaitingCancellation = false
        return .applicationFallback
    }

    mutating func cancellationRequested() {
        guard peripheralID != nil else { return }
        awaitingCancellation = true
        preparedBeforeDidConnect = false
    }

    /// Only an attempt which actually sent the new option can reject it.
    mutating func rejectOptionIfUsed(invalidParameters: Bool) -> Bool {
        guard invalidParameters, optionUsedForAttempt, !optionRejected else { return false }
        optionRejected = true
        return true
    }

    /// Power loss/terminal callbacks release ownership, not the process-local
    /// compatibility fallback. No timeout ever clears an OS-owned request.
    mutating func clearConnection() {
        peripheralID = nil
        systemOwnsPendingConnection = false
        awaitingCancellation = false
        optionUsedForAttempt = false
        connectsSinceBoundary = 0
        lastDisconnectTimestamp = nil
        lastDisconnectWasReconnecting = false
        preparedBeforeDidConnect = false
    }
}
