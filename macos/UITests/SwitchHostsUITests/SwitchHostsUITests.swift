import XCTest

/// Launches the built SwitchHosts.app with a temporary HOME seeded with a small
/// tree, then checks what is on screen. The tests only read and select: they do
/// not toggle entries, save content, or change the data folder.
final class SwitchHostsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var home: URL!

    /// The app bundle built by macos/scripts/make-app.sh, unless SWH_APP_PATH says otherwise.
    private var appURL: URL {
        if let path = ProcessInfo.processInfo.environment["SWH_APP_PATH"] {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwitchHostsUITests/
            .deletingLastPathComponent()  // UITests/
            .deletingLastPathComponent()  // macos/
            .appendingPathComponent("build/SwitchHosts.app")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("swh-uitest-\(UUID().uuidString)", isDirectory: true)
        try seedData(in: home.appendingPathComponent(".SwitchHosts", isDirectory: true))

        app = XCUIApplication(url: appURL)
        app.launchEnvironment["HOME"] = home.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    func testTheWindowListsTheSeededEntries() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the main window opens")
        let outline = app.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "the sidebar is present")
        // System Hosts, the top-level entries, and the folder's children.
        XCTAssertGreaterThanOrEqual(outline.outlineRows.count, 5)
        XCTAssertTrue(app.staticTexts["团队环境"].exists, "the folder is listed")
    }

    func testSelectingAFolderShowsItsChoiceMode() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let folder = app.staticTexts["团队环境"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.click()
        // The folder pane has the three-way choice mode control.
        XCTAssertTrue(app.segmentedControls.firstMatch.waitForExistence(timeout: 10), "the choice mode control appears")
    }

    func testCommandCommaOpensThePreferencesWindow() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let before = app.windows.count
        app.typeKey(",", modifierFlags: .command)
        let opened = NSPredicate { _, _ in self.app.windows.count > before }
        let expectation = XCTNSPredicateExpectation(predicate: opened, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, "the settings window opens")
    }

    /// A tree with one folder, one remote-free local entry set, and no writes to /etc/hosts.
    private func seedData(in root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("internal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("entries"), withIntermediateDirectories: true)
        let manifest = """
        {"format": "switchhosts-data", "schemaVersion": 1, "root": [
          {"id": "web", "type": "local", "title": "前端站点", "on": false},
          {"id": "team", "type": "folder", "title": "团队环境", "on": false, "folder": {"mode": 0}, "children": [
            {"id": "dev", "type": "local", "title": "开发环境", "on": false},
            {"id": "api", "type": "local", "title": "API 服务", "on": false}
          ]},
          {"id": "staging", "type": "local", "title": "预发布", "on": false}
        ]}
        """
        try manifest.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        // An empty write mode means toggles are refused before anything is written to /etc/hosts.
        try #"{"write_mode": ""}"#.write(to: root.appendingPathComponent("internal/config.json"), atomically: true, encoding: .utf8)
        for id in ["web", "dev", "api", "staging"] {
            try "10.0.0.1 \(id).example.test\n".write(to: root.appendingPathComponent("entries/\(id).hosts"), atomically: true, encoding: .utf8)
        }
    }
}
