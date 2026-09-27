import Foundation

/// A discovered bike is selected and its preferences are committed before the
/// first synchronous connection request can observe them. Selection must not
/// call the general reconnect setter, which may connect the previously saved bike.
enum BLEDiscoverySelection {
    static func connect(_ identifier: UUID, automaticallyReconnect preferenceOverride: Bool?,
                        currentPreference: Bool,
                        commit: (UUID, Bool) -> Void,
                        issue: (UUID) -> Void) {
        commit(identifier, preferenceOverride ?? currentPreference)
        issue(identifier)
    }
}
