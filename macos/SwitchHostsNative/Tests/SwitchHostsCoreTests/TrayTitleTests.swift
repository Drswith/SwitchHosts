import XCTest
@testable import SwitchHostsCore

final class TrayTitleTests: XCTestCase {
    private func node(_ id: String, _ title: String, on: Bool, children: [HostsNode]? = nil) throws -> HostsNode {
        let json: [String: Any] = [
            "id": id, "title": title, "type": "local", "on": on,
            "children": (children ?? []).map { ["id": $0.id, "title": $0.title ?? "", "on": $0.isOn] as [String: Any] },
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(HostsNode.self, from: data)
    }

    func testHiddenWhenTheOptionIsOff() throws {
        let nodes = [try node("a", "Dev", on: true)]
        XCTAssertNil(TrayTitle.make(nodes, show: false))
    }

    func testListsEveryEntryThatIsOn() throws {
        let nodes = [
            try node("a", "Dev", on: true),
            try node("b", "Staging", on: false),
            try node("c", "Team", on: true, children: []),
        ]
        XCTAssertEqual(TrayTitle.make(nodes, show: true), "Dev,Team")
    }

    func testLongTitlesAreShortenedToSeventeenCharactersPlusEllipsis() throws {
        let nodes = [try node("a", "abcdefghijklmnopqrstuvwxyz", on: true)]
        XCTAssertEqual(TrayTitle.make(nodes, show: true), "abcdefghijklmnopq...")
    }

    func testEmptyWhenNothingIsOn() throws {
        let nodes = [try node("a", "Dev", on: false)]
        XCTAssertEqual(TrayTitle.make(nodes, show: true), "")
    }
}
