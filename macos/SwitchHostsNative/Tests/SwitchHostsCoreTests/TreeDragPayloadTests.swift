import AppKit
import XCTest
@testable import SwitchHostsCore

final class TreeDragPayloadTests: XCTestCase {
    /// The id a row offers must come back unchanged from the drop side.
    func testTheDraggedIdSurvivesTheProviderRoundTrip() async {
        let provider = TreeDragPayload.provider(for: "entry-123")
        let id = await TreeDragPayload.id(from: provider)
        XCTAssertEqual(id, "entry-123")
    }

    func testAnEmptyIdStaysEmpty() async {
        let id = await TreeDragPayload.id(from: TreeDragPayload.provider(for: ""))
        XCTAssertEqual(id, "")
    }
}
