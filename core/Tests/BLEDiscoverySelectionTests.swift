import Foundation
import XCTest
@testable import MotoLinkCore

final class BLEDiscoverySelectionTests: XCTestCase {
    private let newBike = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let oldBike = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testFirstSelectionCommitsBeforeSingleNativeRequest() {
        var remembered: UUID?
        var native = BLENativeReconnectPolicy()
        var requests: [(UUID, Bool)] = []
        BLEDiscoverySelection.connect(newBike, commit: { identifier in
                remembered = identifier
            }, issue: { identifier in
                XCTAssertEqual(remembered, identifier)
                let option = native.connectionRequested(for: identifier, supported: true, enabled: remembered != nil)
                requests.append((identifier, option))
            })
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.0, newBike)
        XCTAssertEqual(requests.first?.1, true)
    }

    func testSelectingAnotherBikeNeverIssuesRequestForPreviouslyRememberedBike() {
        var remembered = oldBike
        var requests: [UUID] = []
        BLEDiscoverySelection.connect(newBike, commit: { identifier in
                remembered = identifier
            }, issue: { identifier in
                XCTAssertEqual(remembered, newBike)
                requests.append(identifier)
            })
        XCTAssertEqual(requests, [newBike])
        XCTAssertFalse(requests.contains(oldBike))
    }

}
