import SwitchHostsCore
import XCTest
@testable import SwitchHostsNative

/// What each sidebar view lists and counts.
final class LibraryTests: XCTestCase {
    /// basic, dev, shared at the top; Project A holds env1, env2, and a nested
    /// folder with one remote entry; then a group and one more local entry.
    private let tree: [HostsNode] = try! JSONDecoder().decode([HostsNode].self, from: Data("""
    [
      {"id": "basic", "type": "local", "title": "basic", "on": true},
      {"id": "dev", "type": "local", "title": "dev", "on": false},
      {"id": "shared", "type": "remote", "title": "shared", "on": true, "url": "https://example.test/hosts"},
      {"id": "projA", "type": "folder", "title": "Project A", "on": false, "children": [
        {"id": "env1", "type": "local", "title": "env1", "on": true},
        {"id": "env2", "type": "local", "title": "Env2", "on": false},
        {"id": "sub", "type": "folder", "title": "Nested", "on": false, "children": [
          {"id": "deep", "type": "remote", "title": "Deep Remote", "on": false}
        ]}
      ]},
      {"id": "combo", "type": "group", "title": "combo", "on": false, "include": ["basic"]},
      {"id": "test"}
    ]
    """.utf8))

    private func ids(_ nodes: [HostsNode]) -> [String] { nodes.map(\.id) }

    func testAllListsEveryNonFolderEntryDepthFirst() {
        XCTAssertEqual(ids(Library.rows(for: .all, in: tree)),
                       ["basic", "dev", "shared", "env1", "env2", "deep", "combo", "test"])
    }

    func testActiveListsTheEntriesThatAreOn() {
        XCTAssertEqual(ids(Library.rows(for: .active, in: tree)), ["basic", "shared", "env1"])
    }

    func testRemoteListsRemoteEntriesAtAnyDepth() {
        XCTAssertEqual(ids(Library.rows(for: .remote, in: tree)), ["shared", "deep"])
    }

    func testAFolderListsItsDirectChildrenOnly() {
        XCTAssertEqual(ids(Library.rows(for: .folder("projA"), in: tree)), ["env1", "env2", "sub"])
        XCTAssertEqual(ids(Library.rows(for: .folder("sub"), in: tree)), ["deep"])
        XCTAssertEqual(ids(Library.rows(for: .folder("missing"), in: tree)), [])
        XCTAssertEqual(ids(Library.rows(for: .folder("basic"), in: tree)), [], "an entry is not a folder")
    }

    func testViewsWithoutTreeEntriesListNone() {
        XCTAssertTrue(Library.rows(for: .system, in: tree).isEmpty)
        XCTAssertTrue(Library.rows(for: .trash, in: tree).isEmpty)
    }

    func testCounts() {
        XCTAssertEqual(Library.counts(in: tree), Library.Counts(all: 8, active: 3, remote: 2))
        XCTAssertEqual(Library.counts(in: []), Library.Counts())
    }

    func testSearchMatchesTitlesIgnoringCase() {
        let all = Library.rows(for: .all, in: tree)
        XCTAssertEqual(ids(Library.matching(all, query: "ENV")), ["env1", "env2"])
        XCTAssertEqual(ids(Library.matching(all, query: " remote ")), ["deep"])
        XCTAssertEqual(ids(Library.matching(all, query: "  ")), ids(all), "a blank search keeps every row")
        XCTAssertEqual(ids(Library.matching(all, query: "nothing like it")), [])
    }

    func testFoldersAreListedDepthFirstWithTheirDepth() {
        XCTAssertEqual(Library.folders(in: tree), [
            FolderOption(id: "projA", title: "Project A", depth: 0),
            FolderOption(id: "sub", title: "Nested", depth: 1),
        ])
    }

    func testParentIsTheFolderThatDirectlyHoldsTheEntry() {
        XCTAssertEqual(Library.parent(of: "deep", in: tree)?.id, "sub")
        XCTAssertEqual(Library.parent(of: "env1", in: tree)?.id, "projA")
        XCTAssertNil(Library.parent(of: "basic", in: tree))
        XCTAssertNil(Library.parent(of: "missing", in: tree))
    }

    func testNothingMovesIntoItsOwnSubtree() {
        XCTAssertTrue(Library.isInSubtree("projA", of: "projA", in: tree))
        XCTAssertTrue(Library.isInSubtree("sub", of: "projA", in: tree))
        XCTAssertTrue(Library.isInSubtree("deep", of: "projA", in: tree))
        XCTAssertFalse(Library.isInSubtree("basic", of: "projA", in: tree))
        XCTAssertFalse(Library.isInSubtree("projA", of: "sub", in: tree))
        XCTAssertFalse(Library.isInSubtree("env1", of: "basic", in: tree), "an entry holds nothing")
    }

    func testLineCountMatchesTheGutter() {
        XCTAssertEqual(Library.lineCount(of: ""), 0)
        XCTAssertEqual(Library.lineCount(of: "127.0.0.1 a"), 1)
        XCTAssertEqual(Library.lineCount(of: "127.0.0.1 a\n"), 2)
        XCTAssertEqual(Library.lineCount(of: "a\nb\n\n"), 4)
        XCTAssertEqual(Library.lineCount(of: "a\r\nb\r\nc"), 3, "Windows line endings count once")
    }

    func testSidebarItemsSurviveStorage() {
        let items: [SidebarItem] = [.system, .all, .active, .remote, .trash, .folder("a:b-c")]
        for item in items {
            XCTAssertEqual(SidebarItem(storageValue: item.storageValue), item)
        }
        XCTAssertNil(SidebarItem(storageValue: "folder:"))
        XCTAssertNil(SidebarItem(storageValue: "unknown"))
    }

    func testOnlyAllAndFoldersCanBeReordered() {
        XCTAssertTrue(SidebarItem.all.allowsReordering)
        XCTAssertTrue(SidebarItem.folder("x").allowsReordering)
        XCTAssertFalse(SidebarItem.active.allowsReordering)
        XCTAssertFalse(SidebarItem.remote.allowsReordering)
        XCTAssertFalse(SidebarItem.system.allowsReordering)
        XCTAssertFalse(SidebarItem.trash.allowsReordering)
    }

    /// The gutter counts lines on UTF-16 units, the way the header counts them.
    @MainActor
    func testTheGutterCountsLineFeedsOnly() {
        let text = "a\r\nb\nc\n" as NSString
        XCTAssertEqual(LineNumberRuler.newlineCount(in: text, NSRange(location: 0, length: text.length)), 3)
        XCTAssertEqual(LineNumberRuler.newlineCount(in: text, NSRange(location: 3, length: 3)), 1)
    }
}
