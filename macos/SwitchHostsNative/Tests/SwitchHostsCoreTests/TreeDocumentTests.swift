import XCTest
@testable import SwitchHostsCore

final class TreeDocumentTests: XCTestCase {
    private func sample() -> [TreeDocument.Node] {
        [
            ["id": "a", "type": "local", "title": "A", "on": false],
            ["id": "f", "type": "folder", "title": "F", "on": false, "folder": ["mode": 0],
             "children": [["id": "b", "type": "local", "title": "B", "on": false]]],
        ]
    }

    func testFindReturnsTheNodeAndItsAncestors() {
        let found = TreeDocument.find("b", in: sample())
        XCTAssertEqual(found?.node["title"] as? String, "B")
        XCTAssertEqual(found?.ancestors, ["f"])
    }

    func testAppendLocalAddsToTopLevelOrIntoAFolder() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.appendLocal(id: "n1", title: "New", parentID: nil, to: &tree))
        XCTAssertEqual(tree.last?["id"] as? String, "n1")

        XCTAssertTrue(TreeDocument.appendLocal(id: "n2", title: "Inner", parentID: "f", to: &tree))
        let folder = TreeDocument.find("f", in: tree)?.node["children"] as? [TreeDocument.Node]
        XCTAssertEqual(folder?.last?["id"] as? String, "n2")
    }

    func testAppendLocalRefusesANonFolderParent() {
        var tree = sample()
        XCTAssertFalse(TreeDocument.appendLocal(id: "n", title: "X", parentID: "a", to: &tree))
    }

    func testRenameChangesOnlyTheTitleOfTheTarget() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.rename("b", to: "Renamed", in: &tree))
        XCTAssertEqual(TreeDocument.find("b", in: tree)?.node["title"] as? String, "Renamed")
        XCTAssertEqual(TreeDocument.find("a", in: tree)?.node["title"] as? String, "A")
    }

    func testRemoveDropsNestedNodes() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.remove("b", from: &tree))
        XCTAssertNil(TreeDocument.find("b", in: tree))
        XCTAssertFalse(TreeDocument.remove("missing", from: &tree))
    }

    func testUnknownFieldsSurviveAnEdit() {
        var tree: [TreeDocument.Node] = [["id": "a", "type": "local", "title": "A", "on": false, "extras": ["k": 1]]]
        TreeDocument.rename("a", to: "Z", in: &tree)
        XCTAssertEqual((tree[0]["extras"] as? [String: Any])?["k"] as? Int, 1)
    }

    func testMoveSiblingSwapsWithTheNeighbour() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.moveSibling("a", by: 1, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["f", "a"])
        XCTAssertTrue(TreeDocument.moveSibling("a", by: -1, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["a", "f"])
    }

    func testMoveSiblingStopsAtTheEdgeAndReachesNestedNodes() {
        var tree = sample()
        XCTAssertFalse(TreeDocument.moveSibling("a", by: -1, in: &tree))
        XCTAssertFalse(TreeDocument.moveSibling("b", by: 1, in: &tree), "the only child cannot move down")
        XCTAssertFalse(TreeDocument.moveSibling("missing", by: 1, in: &tree))
    }

    func testAppendRemoteStoresTheAddressAndInterval() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.appendRemote(id: "r", title: "R", url: "https://example.com/hosts",
                                                domains: nil, refreshInterval: 3600, parentID: nil, to: &tree))
        let node = TreeDocument.find("r", in: tree)?.node
        XCTAssertEqual(node?["type"] as? String, "remote")
        XCTAssertEqual(node?["source"] as? String, "url")
        XCTAssertEqual(node?["url"] as? String, "https://example.com/hosts")
        XCTAssertEqual(node?["refresh_interval"] as? Int, 3600)
    }

    func testAppendRemoteAcceptsADomainList() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.appendRemote(id: "d", title: "D", url: nil,
                                                domains: ["a.example.test", "b.example.test"],
                                                refreshInterval: 0, parentID: "f", to: &tree))
        let node = TreeDocument.find("d", in: tree)?.node
        XCTAssertEqual(node?["source"] as? String, "domain")
        XCTAssertEqual(node?["domains"] as? [String], ["a.example.test", "b.example.test"])
    }

    func testSetRemoteTargetSwitchesSourceAndOnlyAppliesToRemoteEntries() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.appendRemote(id: "r", title: "R", url: "https://a.example/hosts",
                                                domains: nil, refreshInterval: 0, parentID: nil, to: &tree))
        XCTAssertTrue(TreeDocument.setRemoteTarget("r", url: nil, domains: ["c.example.test"], in: &tree))
        let node = TreeDocument.find("r", in: tree)?.node
        XCTAssertEqual(node?["source"] as? String, "domain")
        XCTAssertEqual(node?["domains"] as? [String], ["c.example.test"])
        XCTAssertFalse(TreeDocument.setRemoteTarget("a", url: "https://x.example", domains: nil, in: &tree),
                       "a local entry is not a remote target")
    }

    func testSetRefreshIntervalChangesOnlyTheRemoteEntry() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.appendRemote(id: "r", title: "R", url: "https://a.example/hosts",
                                                domains: nil, refreshInterval: 0, parentID: nil, to: &tree))
        XCTAssertTrue(TreeDocument.setRefreshInterval("r", seconds: 86400, in: &tree))
        XCTAssertEqual(TreeDocument.find("r", in: tree)?.node["refresh_interval"] as? Int, 86400)
        XCTAssertFalse(TreeDocument.setRefreshInterval("a", seconds: 60, in: &tree))
    }

    func testCollapseAndChoiceModeApplyToFoldersOnly() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.setCollapsed("f", true, in: &tree))
        XCTAssertEqual(TreeDocument.find("f", in: tree)?.node["is_collapsed"] as? Bool, true)
        XCTAssertFalse(TreeDocument.setCollapsed("a", true, in: &tree), "a local entry cannot collapse")

        XCTAssertTrue(TreeDocument.setFolderMode("f", mode: 1, in: &tree))
        XCTAssertEqual(TreeDocument.find("f", in: tree)?.node["folder_mode"] as? Int, 1)
        XCTAssertFalse(TreeDocument.setFolderMode("b", mode: 1, in: &tree))
        XCTAssertFalse(TreeDocument.setFolderMode("missing", mode: 1, in: &tree))
    }

    func testMoveIntoAFolderAndToTheTopLevel() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.move("a", toFolder: "f", in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["f"])
        let inside = TreeDocument.find("f", in: tree)?.node["children"] as? [TreeDocument.Node]
        XCTAssertEqual(inside?.map { $0["id"] as? String }, ["b", "a"])

        XCTAssertTrue(TreeDocument.move("b", toFolder: nil, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["f", "b"])
    }

    func testMoveRefusesTargetsThatAreNotFoldersOrAreInsideTheMovedNode() {
        var tree = sample()
        XCTAssertFalse(TreeDocument.move("a", toFolder: "a", in: &tree), "a node cannot go into itself")
        XCTAssertFalse(TreeDocument.move("a", toFolder: "b", in: &tree), "a local entry is not a folder")
        XCTAssertFalse(TreeDocument.move("f", toFolder: "b", in: &tree))
        XCTAssertFalse(TreeDocument.move("missing", toFolder: nil, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["a", "f"], "a refused move changes nothing")

        let nested = [["id": "p", "type": "folder", "title": "P", "on": false,
                       "children": [["id": "q", "type": "folder", "title": "Q", "on": false, "children": []]]]] as [TreeDocument.Node]
        var deep = nested
        XCTAssertFalse(TreeDocument.move("p", toFolder: "q", in: &deep), "a folder cannot move into its own child")
        XCTAssertEqual(deep.first?["id"] as? String, "p")
    }

    func testDropBeforeAndAfterASibling() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.move("f", relativeTo: "a", placement: .before, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["f", "a"])
        XCTAssertTrue(TreeDocument.move("f", relativeTo: "a", placement: .after, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["a", "f"])
    }

    func testDropInsideAFolderOrNextToAChild() {
        var tree = sample()
        XCTAssertTrue(TreeDocument.move("a", relativeTo: "f", placement: .inside, in: &tree))
        let inside = TreeDocument.find("f", in: tree)?.node["children"] as? [TreeDocument.Node]
        XCTAssertEqual(inside?.map { $0["id"] as? String }, ["b", "a"])

        XCTAssertTrue(TreeDocument.move("a", relativeTo: "b", placement: .before, in: &tree))
        let reordered = TreeDocument.find("f", in: tree)?.node["children"] as? [TreeDocument.Node]
        XCTAssertEqual(reordered?.map { $0["id"] as? String }, ["a", "b"], "a child can be reordered inside its folder")
        XCTAssertEqual(TreeDocument.find("a", in: tree)?.ancestors, ["f"])
    }

    func testDropRefusesSelfDescendantsAndNonFolders() {
        var tree = sample()
        XCTAssertFalse(TreeDocument.move("a", relativeTo: "a", placement: .before, in: &tree))
        XCTAssertFalse(TreeDocument.move("a", relativeTo: "b", placement: .inside, in: &tree), "b is not a folder")
        XCTAssertFalse(TreeDocument.move("f", relativeTo: "b", placement: .after, in: &tree), "a folder cannot land inside itself")
        XCTAssertFalse(TreeDocument.move("a", relativeTo: "missing", placement: .before, in: &tree))
        XCTAssertEqual(tree.map { $0["id"] as? String }, ["a", "f"], "refused drops change nothing")
    }
}

