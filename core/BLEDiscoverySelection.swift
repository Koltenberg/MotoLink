import Foundation

/// Commit the selected bike before issuing its first connection. Never route
/// selection through connectRemembered, which could connect the previous bike.
enum BLEDiscoverySelection {
    static func connect(_ identifier: UUID,
                        commit: (UUID) -> Void,
                        issue: (UUID) -> Void) {
        commit(identifier)
        issue(identifier)
    }
}
