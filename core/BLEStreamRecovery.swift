import Foundation

/// Recovery for an established stream that goes silent while GATT stays linked.
/// These are app recovery windows, not Kawasaki keepalive intervals. Callers use
/// monotonic uptime and report only structurally valid 4A frames.
struct BLEStreamRecoveryPolicy {
    enum Action: Equatable { case retryInitialProfile, rearmStream, preserveActiveLink, preserveSilentLink }

    static let staleInterval: TimeInterval = 45
    static let rearmGraceInterval: TimeInterval = 30
    private(set) var lastStreamAt: TimeInterval?
    private var lastPacketAt: TimeInterval?
    private(set) var rearmUsed = false
    private var rearmedAt: TimeInterval?
    private var lastObservedAt: TimeInterval?
    private var reportedActiveLink = false
    private var reportedSilentLink = false
    private var initialProfileRetryAt: TimeInterval?
    private var initialProfileRetryUsed = false

    var initialProfileRetryPending: Bool { initialProfileRetryAt != nil }

    /// Only a completed write-error callback can arm this retry. A missing ATT
    /// callback still owns its write and must never allow another command.
    @discardableResult
    mutating func initialProfileWriteFailed(at now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0, (now + Self.staleInterval).isFinite,
              lastStreamAt == nil, !initialProfileRetryUsed,
              initialProfileRetryAt == nil else { return false }
        initialProfileRetryAt = now + Self.staleInterval
        return true
    }

    /// A manual or restoration-triggered profile supersedes a scheduled retry.
    mutating func initialProfileStarted() {
        if initialProfileRetryAt != nil {
            initialProfileRetryAt = nil
            initialProfileRetryUsed = true
        }
    }

    static func isPacket(_ data: Data) -> Bool {
        let bytes = Array(data)
        return bytes.count >= 3 && bytes.count == Int(bytes[1]) + 3
    }

    /// Unknown measurement formats must not be mistaken for a silent transport.
    static func isStreamFrame(_ data: Data) -> Bool {
        let bytes = Array(data)
        return bytes.count >= 15 && bytes[0] == 0x4A && bytes.count == Int(bytes[1]) + 3
    }

    mutating func receivedStream(at now: TimeInterval) {
        guard now.isFinite, now >= 0 else { return }
        receivedPacket(at: now)
        lastStreamAt = now
        initialProfileRetryAt = nil
        rearmedAt = nil
        reportedActiveLink = false
        reportedSilentLink = false
    }

    mutating func receivedPacket(at now: TimeInterval) {
        guard now.isFinite, now >= 0 else { return }
        if let previous = lastObservedAt, now < previous {
            if lastStreamAt != nil { lastStreamAt = now }
            if rearmedAt != nil { rearmedAt = now }
        }
        lastObservedAt = now
        lastPacketAt = now
    }

    mutating func nextAction(at now: TimeInterval, eligible: Bool) -> Action? {
        guard now.isFinite, now >= 0 else { return nil }
        if let previous = lastObservedAt, now < previous {
            // Rebase an invalid clock source without interpreting it as silence.
            if lastStreamAt != nil { lastStreamAt = now }
            if lastPacketAt != nil { lastPacketAt = now }
            if rearmedAt != nil { rearmedAt = now }
            if initialProfileRetryAt != nil { initialProfileRetryAt = now + Self.staleInterval }
        }
        lastObservedAt = now
        guard eligible else { return nil }
        if let initialProfileRetryAt, lastStreamAt == nil,
           now >= initialProfileRetryAt {
            self.initialProfileRetryAt = nil
            initialProfileRetryUsed = true
            return .retryInitialProfile
        }
        guard let lastStreamAt,
              now - lastStreamAt >= Self.staleInterval else { return nil }
        if let rearmedAt {
            guard now - rearmedAt >= Self.rearmGraceInterval else { return nil }
        }
        if rearmUsed {
            // Kawasaki can limit discovery after riding begins. Do not surrender
            // a connected ACL merely because notifications stopped. CoreBluetooth
            // owns the physical disconnect decision; wait for its callback.
            if let lastPacketAt, now - lastPacketAt < Self.rearmGraceInterval {
                guard !reportedActiveLink else { return nil }
                reportedActiveLink = true
                return .preserveActiveLink
            }
            guard !reportedSilentLink else { return nil }
            reportedSilentLink = true
            return .preserveSilentLink
        }
        rearmUsed = true
        rearmedAt = now
        return .rearmStream
    }

    mutating func reset() { self = Self() }
}
