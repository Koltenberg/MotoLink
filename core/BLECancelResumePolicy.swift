import Foundation

/// Keeps a new user request separate from an in-flight CoreBluetooth cancel.
/// The closing connection must remain unwanted until its terminal callback;
/// otherwise a racing didConnect could be accepted before cancellation finishes.
struct BLECancelResumePolicy {
    private(set) var cancellingPeripheralID: UUID?
    private(set) var resumeAfterCancellation = false

    mutating func requestedCancellation(for identifier: UUID) {
        cancellingPeripheralID = identifier
        resumeAfterCancellation = false
    }

    /// False means there is no matching cancel to wait for. The caller may use
    /// its ordinary connect path once it owns no current peripheral.
    @discardableResult
    mutating func requestedResume(for identifier: UUID) -> Bool {
        guard cancellingPeripheralID == identifier else { return false }
        resumeAfterCancellation = true
        return true
    }

    /// Stop/off revokes the queued request without forgetting the pending cancel.
    mutating func revokeResume() { resumeAfterCancellation = false }

    /// Consume exactly once, and only after the actual peripheral finishes.
    mutating func completedCancellation(for identifier: UUID, canResume: Bool) -> Bool {
        guard cancellingPeripheralID == identifier else { return false }
        let shouldResume = resumeAfterCancellation && canResume
        reset()
        return shouldResume
    }

    mutating func reset() { self = Self() }
}
