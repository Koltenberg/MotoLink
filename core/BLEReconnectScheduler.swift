import Foundation

/// Enforces a real app-side cooldown before issuing another connect request.
/// CoreBluetooth can reject connect options immediately, so an option passed
/// to connect must never be the only thing limiting a failure/callback loop.
/// A suspended app waits until its next execution opportunity; this does not
/// promise a timer wakeup or cancel a connection already owned by iOS.
struct BLEReconnectScheduler {
    struct Ticket: Equatable {
        fileprivate let generation: UInt64
        let notBefore: TimeInterval
    }

    private var generation: UInt64 = 0
    private(set) var pending: Ticket?

    @discardableResult
    mutating func schedule(after delay: TimeInterval, now: TimeInterval) -> Ticket? {
        cancel()
        guard now.isFinite, now >= 0, delay.isFinite, delay >= 0,
              (now + delay).isFinite else { return nil }
        let ticket = Ticket(generation: generation, notBefore: now + delay)
        pending = ticket
        return ticket
    }

    /// nil means stale/cancelled work or an invalid clock; zero means eligible.
    func remaining(for ticket: Ticket, now: TimeInterval) -> TimeInterval? {
        guard ticket == pending, now.isFinite, now >= 0 else { return nil }
        return max(0, ticket.notBefore - now)
    }

    /// Only the first callback at/after the deadline may issue the connection.
    mutating func consume(_ ticket: Ticket, now: TimeInterval) -> Bool {
        guard remaining(for: ticket, now: now) == 0 else { return false }
        pending = nil
        return true
    }

    mutating func cancel() {
        generation &+= 1
        pending = nil
    }
}
