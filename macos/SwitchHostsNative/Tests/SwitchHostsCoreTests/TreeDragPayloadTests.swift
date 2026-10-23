import AppKit
import UniformTypeIdentifiers
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

    /// Text dragged from another app is not an entry id, and a row is not text.
    func testRowsAndPlainTextDoNotMix() async {
        let text = NSItemProvider(object: "entry-123" as NSString)
        XCTAssertFalse(text.hasItemConformingToTypeIdentifier(TreeDragPayload.type.identifier))
        let row = TreeDragPayload.provider(for: "entry-123")
        XCTAssertFalse(row.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
    }
}
