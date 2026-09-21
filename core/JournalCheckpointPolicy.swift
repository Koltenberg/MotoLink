import Foundation

/// Raw records are written on every append. Only fsync and the atomic summary
/// checkpoint are coalesced; explicit boundaries always force persistence.
struct JournalCheckpointPolicy {
    private(set) var lastCheckpointUptime: TimeInterval?
    let interval: TimeInterval = 1

    func shouldCheckpoint(at uptime: TimeInterval, forced: Bool = false) -> Bool {
        guard !forced, let previous = lastCheckpointUptime else { return true }
        return !uptime.isFinite || uptime < previous || uptime - previous >= interval
    }

    /// Call only after both synchronization and the manifest write succeed.
    mutating func checkpointSucceeded(at uptime: TimeInterval) {
        lastCheckpointUptime = uptime.isFinite ? uptime : nil
    }
}
