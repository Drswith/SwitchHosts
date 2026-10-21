import XCTest
@testable import SwitchHostsNative

/// A HOME folder with seeded SwitchHosts data, so a `HostsModel` can start
/// against it. The real data and /etc/hosts are never read or changed: the
/// write mode is empty and nothing here switches an entry on.
final class TemporaryHome {
    let url: URL
    let data: URL
    private let savedHome: String?

    init(manifest: String, contents: [String: String] = [:]) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swh-model-\(UUID().uuidString)", isDirectory: true)
        data = url.appendingPathComponent(".SwitchHosts")
        let fm = FileManager.default
        try fm.createDirectory(at: data.appendingPathComponent("internal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: data.appendingPathComponent("entries"), withIntermediateDirectories: true)
        try manifest.write(to: data.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        // No update check (no network) and no write mode (nothing can be applied).
        try #"{"write_mode": "", "auto_check_update": false}"#
            .write(to: data.appendingPathComponent("internal/config.json"), atomically: true, encoding: .utf8)
        savedHome = ProcessInfo.processInfo.environment["HOME"]
        for (id, text) in contents {
            try text.write(to: entryFile(id), atomically: true, encoding: .utf8)
        }
        setenv("HOME", url.path, 1)
    }

    func entryFile(_ id: String) -> URL {
        data.appendingPathComponent("entries/\(id).hosts")
    }

    func savedText(_ id: String) -> String? {
        try? String(contentsOf: entryFile(id), encoding: .utf8)
    }

    func restore() {
        if let savedHome { setenv("HOME", savedHome, 1) }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Local entries save themselves: after typing pauses, and at once when the
/// selection changes. There is no Save button.
@MainActor
final class AutosaveTests: XCTestCase {
    private var home: TemporaryHome!
    private var model: HostsModel!

    override func setUp() async throws {
        home = try TemporaryHome(
            manifest: """
            {"format": "switchhosts-data", "schemaVersion": 1, "root": [
              {"id": "a", "type": "local", "title": "A", "on": false},
              {"id": "b", "type": "local", "title": "B", "on": false},
              {"id": "r", "type": "remote", "title": "R", "on": false, "url": "file:///nonexistent"}
            ]}
            """,
            contents: ["a": "10.0.0.1 a.example.test\n", "b": "10.0.0.2 b.example.test\n"]
        )
        model = HostsModel(defaults: UserDefaults(suiteName: "swh-autosave-\(UUID().uuidString)")!)
        await model.start()
    }

    override func tearDown() async throws {
        model = nil
        home?.restore()
    }

    func testFlushWritesTheEditsAndClearsDirty() async {
        await model.select("a")
        XCTAssertEqual(model.content, "10.0.0.1 a.example.test\n")
        model.content = "10.0.0.9 edited.example.test\n"
        XCTAssertTrue(model.isDirty)
        await model.flushAutosave()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(home.savedText("a"), "10.0.0.9 edited.example.test\n")
    }

    func testChangingTheSelectionSavesTheEntryBeingLeft() async {
        await model.select("a")
        model.content = "# changed before switching\n"
        await model.select("b")
        XCTAssertEqual(model.selection, "b")
        XCTAssertEqual(home.savedText("a"), "# changed before switching\n")
        XCTAssertEqual(model.content, "10.0.0.2 b.example.test\n", "the editor shows the new entry's own text")
    }

    func testAPauseSavesTheCurrentText() async throws {
        await model.select("a")
        model.content = "10.0.0.3 paused.example.test\n"
        model.editorPaused(with: model.content)
        try await waitUntil { self.home.savedText("a") == "10.0.0.3 paused.example.test\n" }
        XCTAssertFalse(model.isDirty)
    }

    func testAPauseForOtherTextIsIgnored() async throws {
        await model.select("a")
        model.content = "10.0.0.4 current.example.test\n"
        // A pause that carries text the editor no longer shows writes nothing.
        model.editorPaused(with: "stale text from another entry\n")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(home.savedText("a"), "10.0.0.1 a.example.test\n")
        XCTAssertTrue(model.isDirty)
    }

    func testReadOnlyEntriesAreNotWritten() async {
        await model.select("r")
        model.content = "10.0.0.5 not.saved.example.test\n"
        await model.flushAutosave()
        XCTAssertNil(home.savedText("r"))
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
