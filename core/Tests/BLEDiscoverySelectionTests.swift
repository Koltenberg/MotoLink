import Foundation
import XCTest
@testable import MotoLinkCore

final class BLEDiscoverySelectionTests: XCTestCase {
    private let newBike = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let oldBike = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testFirstDiscoveryOptInCommitsBeforeSingleNativeRequest() {
        var remembered: UUID?
        var preference = false
        var native = BLENativeReconnectPolicy()
        var requests: [(UUID, Bool)] = []
        BLEDiscoverySelection.connect(newBike, automaticallyReconnect: true,
            currentPreference: preference, commit: { identifier, enabled in
                remembered = identifier
                preference = enabled
            }, issue: { identifier in
                XCTAssertEqual(remembered, identifier)
                let option = native.connectionRequested(for: identifier, supported: true, enabled: preference)
                requests.append((identifier, option))
            })
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, newBike)
        XCTAssertEqual(requests.first?.1, true)
    }

    func testSelectingAnotherBikeNeverIssuesRequestForPreviouslyRememberedBike() {
        var remembered = oldBike
        var preference = false
        var requests: [UUID] = []
        BLEDiscoverySelection.connect(newBike, automaticallyReconnect: true,
            currentPreference: preference, commit: { identifier, enabled in
                remembered = identifier
                preference = enabled
            }, issue: { identifier in
                XCTAssertEqual(remembered, newBike)
                XCTAssertTrue(preference)
                requests.append(identifier)
            })
        XCTAssertEqual(requests, [newBike])
        XCTAssertFalse(requests.contains(oldBike))
    }

    func testManualSelectionWithoutOverridePreservesExplicitOffAndOn() {
        for stored in [false, true] {
            var preference = stored
            var native = BLENativeReconnectPolicy()
            var sentOptions: [Bool] = []
            BLEDiscoverySelection.connect(newBike, automaticallyReconnect: nil,
                currentPreference: stored, commit: { _, enabled in preference = enabled },
                issue: { identifier in
                    sentOptions.append(native.connectionRequested(for: identifier,
                        supported: true, enabled: preference))
                })
            XCTAssertEqual(preference, stored)
            XCTAssertEqual(sentOptions, [stored])
        }
    }

    func testExplicitManualOffOverridesStoredOnBeforeIssuingOnce() {
        var preference = true
        var native = BLENativeReconnectPolicy()
        var sentOptions: [Bool] = []
        BLEDiscoverySelection.connect(newBike, automaticallyReconnect: false,
            currentPreference: preference, commit: { _, enabled in preference = enabled },
            issue: { identifier in
                sentOptions.append(native.connectionRequested(for: identifier,
                    supported: true, enabled: preference))
            })
        XCTAssertFalse(preference)
        XCTAssertEqual(sentOptions, [false])
    }
}
