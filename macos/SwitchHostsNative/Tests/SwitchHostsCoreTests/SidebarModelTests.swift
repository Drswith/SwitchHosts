import XCTest
@testable import SwitchHostsNative

/// The sidebar views on a running model: what they select, what they count,
/// and that the choice is remembered. Nothing here switches an entry on, so
/// /etc/hosts is never written.
@MainActor
final class SidebarModelTests: XCTestCase {
    private var home: TemporaryHome!
    private var defaults: UserDefaults!
    private var suiteName: String!

    private func manifest(envOneOn: Bool) -> String {
        """
        {"format": "switchhosts-data", "schemaVersion": 1, "root": [
          {"id": "basic", "type": "local", "title": "basic", "on": true},
          {"id": "dev", "type": "local", "title": "dev", "on": false},
          {"id": "projA", "type": "folder", "title": "Project A", "on": false, "children": [
            {"id": "env1", "type": "local", "title": "env1", "on": \(envOneOn)},
            {"id": "env2", "type": "local", "title": "env2", "on": false}
          ]}
        ]}
        """
    }

    override func setUp() async throws {
        home = try TemporaryHome(
            manifest: manifest(envOneOn: false),
            contents: ["basic": "127.0.0.1 basic.example.test\n", "env1": "# env1\n10.0.0.1 a\n10.0.0.2 b\n"]
        )
        suiteName = "swh-sidebar-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suiteName)
        home?.restore()
    }

    private func startedModel() async -> HostsModel {
        let model = HostsModel(defaults: defaults)
        await model.start()
        return model
    }

    func testFirstLaunchOpensOnTheCurrentSystemHosts() async {
        let model = await startedModel()
        XCTAssertEqual(model.sidebar, .system)
        XCTAssertEqual(model.selection, HostsModel.systemHostsID)
        XCTAssertEqual(model.listedRowIDs.first, HostsModel.systemHostsID)
    }

    func testAViewSelectsItsFirstRowAndIsRemembered() async {
        let model = await startedModel()
        await model.showSidebar(.folder("projA"))
        XCTAssertEqual(model.listedRowIDs, ["env1", "env2"])
        XCTAssertEqual(model.selection, "env1")
        XCTAssertEqual(model.content, "# env1\n10.0.0.1 a\n10.0.0.2 b\n")

        let relaunched = await startedModel()
        XCTAssertEqual(relaunched.sidebar, .folder("projA"))
        XCTAssertEqual(relaunched.selection, "env1")
    }

    func testAForgottenFolderFallsBackToSystemHosts() async {
        defaults.set("folder:gone", forKey: "SidebarSelection")
        let model = await startedModel()
        XCTAssertEqual(model.sidebar, .system)
    }

    func testCountsAndTheActiveListFollowTheTree() async throws {
        let model = await startedModel()
        await model.showSidebar(.active)
        XCTAssertEqual(model.counts, Library.Counts(all: 4, active: 1, remote: 0))
        XCTAssertEqual(model.listedRowIDs, ["basic"])

        // What a committed switch leaves on disk; the window reloads after a toggle.
        try manifest(envOneOn: true).write(to: home.data.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        await model.reload()
        XCTAssertEqual(model.counts.active, 2)
        XCTAssertEqual(model.listedRowIDs, ["basic", "env1"])
    }

    func testTheSearchFiltersTheListByTitle() async {
        let model = await startedModel()
        await model.showSidebar(.all)
        XCTAssertEqual(model.listedRowIDs, ["basic", "dev", "env1", "env2"])
        model.listQuery = "ENV"
        XCTAssertEqual(model.listedRowIDs, ["env1", "env2"])
        // Another view starts with an empty search.
        await model.showSidebar(.active)
        XCTAssertEqual(model.listQuery, "")
    }

    func testCommandAndShiftClicksSelectSeveralEntries() async throws {
        let model = await startedModel()
        await model.showSidebar(.all)
        XCTAssertEqual(model.selection, "basic")
        model.clickRow("env1", modifiers: .command)
        try await waitUntil { model.selection == "env1" }
        XCTAssertEqual(model.selectedIDs, ["basic", "env1"])
        model.clickRow("env2", modifiers: .shift)
        try await waitUntil { model.selection == "env2" }
        XCTAssertEqual(model.selectedIDs, ["env1", "env2"])
        model.clickRow("dev")
        try await waitUntil { model.selection == "dev" }
        XCTAssertEqual(model.selectedIDs, ["dev"])
    }

    func testRowsHiddenBySearchAreLeftOutOfTheTrash() async throws {
        let model = await startedModel()
        await model.showSidebar(.all)
        model.clickRow("env1", modifiers: .command)
        try await waitUntil { model.selection == "env1" }
        XCTAssertEqual(Set(model.trashableSelection), ["basic", "env1"])
        model.listQuery = "env"
        XCTAssertEqual(model.trashableSelection, ["env1"], "basic is hidden by the search")
    }

    func testClickingAFolderRowOpensItsView() async throws {
        let model = await startedModel()
        // A folder view lists the folders nested in it; a click opens one.
        await model.showSidebar(.all)
        model.clickRow("projA")
        try await waitUntil { model.sidebar == .folder("projA") }
        XCTAssertEqual(model.selection, "env1")
    }

    func testANewEntryGoesIntoTheFolderBeingViewed() async throws {
        let model = await startedModel()
        await model.showSidebar(.folder("projA"))
        model.promptNew(.local)
        await model.addEntry(EntryDraft(kind: .local, title: "env3", url: nil, domains: nil, refreshInterval: 0, include: [], folderMode: 0))
        XCTAssertEqual(model.listedEntries.map(\.title), ["env1", "env2", "env3"])
        XCTAssertEqual(model.selectedNode?.title, "env3")
    }

    func testANewEntryOutsideTheActiveViewShowsAllEntries() async throws {
        let model = await startedModel()
        await model.showSidebar(.active)
        model.promptNew(.local)
        await model.addEntry(EntryDraft(kind: .local, title: "fresh", url: nil, domains: nil, refreshInterval: 0, include: [], folderMode: 0))
        XCTAssertEqual(model.sidebar, .all, "a new entry is off, so the Enabled view could not show it")
        XCTAssertEqual(model.selectedNode?.title, "fresh")
        XCTAssertNil(model.parentFolder(of: model.selection ?? ""), "made at the top level")
    }

    func testLineCountsForTheListRows() async throws {
        let model = await startedModel()
        await model.showSidebar(.all)
        try await waitUntil { model.lineCount(of: "env1") != nil }
        XCTAssertEqual(model.lineCount(of: "env1"), 4)
        // The selected entry counts what the editor holds right now.
        XCTAssertEqual(model.selection, "basic")
        model.content = "a\nb\nc"
        XCTAssertEqual(model.lineCount(of: "basic"), 3)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
