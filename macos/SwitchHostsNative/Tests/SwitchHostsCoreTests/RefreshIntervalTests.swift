import XCTest
import SwitchHostsCore
@testable import SwitchHostsNative

/// Remote refresh intervals are offered and labelled as in 5.0.2. The test
/// bundle has no app localizations, so the labels are English.
final class RefreshIntervalTests: XCTestCase {
    func testTheOptionsMatch502() {
        XCTAssertEqual(RefreshInterval.options, [0, 60, 300, 900, 3600, 86400, 604800])
    }

    func testLabelsFollowFormatInterval() {
        XCTAssertEqual(RefreshInterval.label(0), "Never")
        XCTAssertEqual(RefreshInterval.label(45), "45 s")
        XCTAssertEqual(RefreshInterval.label(60), "1 minute")
        XCTAssertEqual(RefreshInterval.label(900), "15 minutes")
        XCTAssertEqual(RefreshInterval.label(3600), "1 hour")
        XCTAssertEqual(RefreshInterval.label(7200), "2 hours")
        XCTAssertEqual(RefreshInterval.label(86400), "1 day")
        XCTAssertEqual(RefreshInterval.label(604800), "7 days")
    }

    func testEveryKindMapsBackFromItsNode() throws {
        let decode = { (json: String) in try JSONDecoder().decode(HostsNode.self, from: Data(json.utf8)) }
        XCTAssertEqual(EntryKind(try decode(#"{"id": "1", "type": "remote"}"#)), .remote)
        XCTAssertEqual(EntryKind(try decode(#"{"id": "2", "type": "group"}"#)), .group)
        XCTAssertEqual(EntryKind(try decode(#"{"id": "3", "type": "folder"}"#)), .folder)
        XCTAssertEqual(EntryKind(try decode(#"{"id": "4"}"#)), .local)
    }
}
