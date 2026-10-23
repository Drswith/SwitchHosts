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

    /// An element whose accessibility label starts with `title`. Sidebar rows
    /// combine their title and count ("团队环境, 2") into one label.
    private func element(titled title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    func testTheSidebarListsTheSeededFolder() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the main window opens")
        XCTAssertTrue(element(titled: "团队环境").waitForExistence(timeout: 10), "the folder is in the sidebar")
    }

    func testSelectingAFolderListsItsEntriesAndChoiceMode() throws {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        let folder = element(titled: "团队环境")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.click()
        XCTAssertTrue(element(titled: "开发环境").waitForExistence(timeout: 10), "the folder's entries are listed")
        // The folder's choice mode is a pop-up menu in the toolbar.
        XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 10), "the choice mode control appears")
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
          {"id": "team", "type": "folder", "title": "团队环境", "on": false, "folder_mode": 0, "children": [
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
