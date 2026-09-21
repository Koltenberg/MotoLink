import Foundation

/// Recovery for an established stream that goes silent while GATT stays linked.
/// These are app recovery windows, not Kawasaki keepalive intervals. Callers use
/// monotonic uptime and report only structurally valid 4A frames.
struct BLEStreamRecoveryPolicy {
    enum Action: Equatable { case rearmStream, preserveActiveLink, restartTransport }

    static let staleInterval: TimeInterval = 45
    static let rearmGraceInterval: TimeInterval = 30
    private(set) var lastStreamAt: TimeInterval?
    private var lastPacketAt: TimeInterval?
    private(set) var rearmUsed = false
    private(set) var restartRequested = false
    private var rearmedAt: TimeInterval?
    private var lastObservedAt: TimeInterval?
    private var reportedActiveLink = false

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
        rearmedAt = nil
        reportedActiveLink = false
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

    /// An optional recovery write may wait for its ATT callback while a working
    /// notification stream continues. Never advance its queue on this evidence.
    func hasRecentPacket(at now: TimeInterval) -> Bool {
        guard now.isFinite, let lastPacketAt, now >= lastPacketAt else { return false }
        return now - lastPacketAt < Self.rearmGraceInterval
    }

    mutating func nextAction(at now: TimeInterval, eligible: Bool) -> Action? {
        guard now.isFinite, now >= 0 else { return nil }
        if let previous = lastObservedAt, now < previous {
            // Rebase an invalid clock source without interpreting it as silence.
            if lastStreamAt != nil { lastStreamAt = now }
            if lastPacketAt != nil { lastPacketAt = now }
            if rearmedAt != nil { rearmedAt = now }
        }
        lastObservedAt = now
        guard eligible, !restartRequested, let lastStreamAt,
              now - lastStreamAt >= Self.staleInterval else { return nil }
        if let rearmedAt {
            guard now - rearmedAt >= Self.rearmGraceInterval else { return nil }
        }
        if rearmUsed {
            // Kawasaki can limit discovery after riding begins. Do not surrender
            // an active ACL when other valid telemetry still proves it works.
            if let lastPacketAt, now - lastPacketAt < Self.rearmGraceInterval {
                guard !reportedActiveLink else { return nil }
                reportedActiveLink = true
                return .preserveActiveLink
            }
            restartRequested = true
            return .restartTransport
        }
        rearmUsed = true
        rearmedAt = now
        return .rearmStream
    }

    mutating func reset() { self = Self() }
}
