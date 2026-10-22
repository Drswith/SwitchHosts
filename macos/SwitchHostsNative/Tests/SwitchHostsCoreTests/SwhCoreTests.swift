import XCTest
@testable import SwitchHostsCore

/// Exercises the C bridge against a temporary data root. These tests never
/// call `toggle_item` or `apply_hosts_selection`, so the real /etc/hosts is
/// never written.
final class SwhCoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swh-swift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVersionComesFromTheCore() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let version = try await core.call(String.self, "version")
        XCTAssertFalse(version.isEmpty)
    }

    func testSetListThenGetListRoundTrips() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [
            ["id": "a", "title": "Dev", "type": "local", "on": false],
            ["id": "b", "title": "Staging", "type": "local", "on": false],
        ]
        try await core.send("set_list", [tree])

        let nodes = try await core.call([HostsNode].self, "get_list")
        XCTAssertEqual(nodes.map(\.id), ["a", "b"])
        XCTAssertEqual(nodes.first?.title, "Dev")
    }

    func testSelectedEntriesAreAggregated() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [
            ["id": "a", "title": "Dev", "type": "local", "on": true],
            ["id": "b", "title": "Off", "type": "local", "on": false],
        ]
        try await core.send("set_list", [tree])
        try await core.send("set_hosts_content", ["a", "127.0.0.1 dev.example.test\n"])
        try await core.send("set_hosts_content", ["b", "10.0.0.9 off.example.test\n"])

        let content = try await core.call(String.self, "get_content_of_list", [tree])
        XCTAssertTrue(content.contains("dev.example.test"))
        XCTAssertFalse(content.contains("off.example.test"))
    }

    func testUnknownCommandSurfacesTheCoreError() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        do {
            _ = try await core.call(String.self, "no_such_command")
            XCTFail("expected an error")
        } catch let SwhError.command(message) {
            XCTAssertTrue(message.contains("unknown command"), message)
        }
    }

    func testCallsAfterCloseThrow() async throws {
        let core = try SwhCore(root: root.path)
        core.close()

        do {
            _ = try await core.call(String.self, "version")
            XCTFail("expected an error")
        } catch SwhError.command {
            // expected
        }
    }

    /// The toggle reaches the core and stops at the write-mode guard. The write
    /// mode is set to empty so the test never writes the real system hosts file.
    func testToggleReportsUnsetWriteModeWithoutTouchingSystemHosts() async throws {
        let internalDir = root.appendingPathComponent("internal", isDirectory: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try Data(#"{"write_mode": ""}"#.utf8).write(to: internalDir.appendingPathComponent("config.json"))

        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": false]]
        try await core.send("set_list", [tree])

        do {
            try await core.send("toggle_item", ["a"])
            XCTFail("expected the write-mode guard to reject the toggle")
        } catch SwhError.command(let message) {
            XCTAssertTrue(message.contains("write mode"), message)
        }

        let nodes = try await core.call([HostsNode].self, "get_list")
        XCTAssertEqual(nodes.first?.isOn, false, "a rejected toggle must not change the saved state")
    }

    /// Re-applying after a content change reaches the core and writes nothing
    /// without a write mode, so the test never touches the real system hosts file.
    func testReapplyWritesNothingWithoutAWriteMode() async throws {
        let internalDir = root.appendingPathComponent("internal", isDirectory: true)
        try FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try Data(#"{"write_mode": ""}"#.utf8).write(to: internalDir.appendingPathComponent("config.json"))

        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": true]]
        try await core.send("set_list", [tree])

        let afterAnEdit = try await core.call(Bool.self, "reapply_saved_selection", [["a"]])
        let afterAReorder = try await core.call(Bool.self, "reapply_saved_selection")
        XCTAssertFalse(afterAnEdit)
        XCTAssertFalse(afterAReorder)
    }

    /// Trash round trip: move out, restore, then move again and delete for good.
    func testTrashRoundTripRestoresAndDeletes() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": false]]
        try await core.send("set_list", [tree])
        try await core.send("move_to_trashcan", ["a"])

        let afterMove = try await core.call([HostsNode].self, "get_list")
        XCTAssertTrue(afterMove.isEmpty)
        let trashed = try await core.call([TrashItem].self, "get_trashcan_list")
        XCTAssertEqual(trashed.map(\.id), ["a"])

        try await core.send("restore_item_from_trashcan", ["a"])
        let restored = try await core.call([HostsNode].self, "get_list")
        XCTAssertEqual(restored.map(\.id), ["a"])

        try await core.send("move_to_trashcan", ["a"])
        try await core.send("delete_item_from_trashcan", ["a"])
        let emptied = try await core.call([TrashItem].self, "get_trashcan_list")
        XCTAssertTrue(emptied.isEmpty)
    }

    /// A save built from an out-of-date read must be rejected, not applied.
    func testSetListRejectsAStaleRead() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let first: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": false]]
        try await core.send("set_list", [first])
        let stale = first
        let newer: [[String: Any]] = [["id": "a", "title": "Changed", "type": "local", "on": false]]
        try await core.send("set_list", [newer, first])

        do {
            try await core.send("set_list", [stale, stale])
            XCTFail("expected the conflict to be reported")
        } catch SwhError.command(let message) {
            XCTAssertTrue(message.contains("changed"), message)
        }
    }

    /// Export a backup, then stage it as an import preview and discard it.
    /// Nothing is written to the tree by the preview.
    func testBackupExportAndImportPreview() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": false]]
        try await core.send("set_list", [tree])
        let backup = root.appendingPathComponent("backup.json")
        try await core.send("export_data", [backup.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        let preview = try await core.json("import_file", [backup.path]) as? [String: Any]
        let list = preview?["list"] as? [Any]
        XCTAssertEqual(list?.count, 1)
        let token = try XCTUnwrap(preview?["id"] as? String)

        try await core.send("import_discard", [token])
        let unchanged = try await core.call([HostsNode].self, "get_list")
        XCTAssertEqual(unchanged.map(\.id), ["a"])
    }

    /// Find across entries, then replace all, and read the content back.
    func testFindAndReplaceAllUpdatesTheEntry() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": false]]
        try await core.send("set_list", [tree])
        try await core.send("set_hosts_content", ["a", "10.0.0.1 old.example.test\n"])

        let options: [String: Any] = ["is_regexp": false, "is_ignore_case": true]
        let found = try await core.call([FindItem].self, "find_by", ["old.example", options])
        XCTAssertEqual(found.map(\.itemId), ["a"])
        XCTAssertEqual(found.first?.count, 1)

        let outcome = try await core.call(ReplaceOutcome.self, "find_replace_all", ["old.example", options, "new.example"])
        XCTAssertEqual(outcome.replacedCount, 1)
        XCTAssertEqual(outcome.itemIds, ["a"])

        let content = try await core.call(String.self, "get_hosts_content", ["a"])
        XCTAssertEqual(content, "10.0.0.1 new.example.test\n")
    }

    /// A preference update is saved and survives reopening the data root.
    func testConfigUpdatePersistsAcrossReopen() async throws {
        let core = try SwhCore(root: root.path)
        try await core.send("config_update", [["write_mode": "overwrite"]])
        let mode = try await core.call(String.self, "config_get", ["write_mode"])
        XCTAssertEqual(mode, "overwrite")
        core.close()

        let reopened = try SwhCore(root: root.path)
        defer { reopened.close() }
        let persisted = try await reopened.call(String.self, "config_get", ["write_mode"])
        XCTAssertEqual(persisted, "overwrite")
    }

    /// Unknown preference keys are refused rather than silently stored.
    func testConfigUpdateRejectsUnknownKeys() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }
        do {
            try await core.send("config_update", [["no_such_preference": 1]])
            XCTFail("expected the unknown key to be rejected")
        } catch SwhError.command {
            // expected
        }
    }

    /// The system hosts file is readable through the core. The call is read-only.
    func testSystemHostsReadsWithoutWriting() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }
        let text = try await core.call(String.self, "get_system_hosts")
        XCTAssertTrue(text.contains("localhost"), "the system file always lists localhost")
    }

    /// Replace one match and leave the other occurrence untouched.
    func testFindReplaceOneChangesOnlyTheChosenMatch() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let tree: [[String: Any]] = [["id": "a", "title": "A", "type": "local", "on": false]]
        try await core.send("set_list", [tree])
        try await core.send("set_hosts_content", ["a", "10.0.0.1 foo.test\n10.0.0.2 foo.test\n"])

        let options: [String: Any] = ["is_regexp": false, "is_ignore_case": false]
        let found = try await core.call([FindItem].self, "find_by", ["foo.test", options])
        let first = try XCTUnwrap(found.first?.positions.first)

        let args: [String: Any] = [
            "item_id": "a",
            "start": first.start,
            "end": first.end,
            "expected": first.match,
            "replace_to": "bar.test",
        ]
        let replaced = try await core.call(Bool.self, "find_replace_one", [args])
        XCTAssertTrue(replaced)

        let content = try await core.call(String.self, "get_hosts_content", ["a"])
        XCTAssertEqual(content, "10.0.0.1 bar.test\n10.0.0.2 foo.test\n")
    }

    /// A remote entry fetches from a file:// source; a failed fetch keeps the old content.
    func testRemoteRefreshFetchesAndKeepsContentOnFailure() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        let source = root.appendingPathComponent("remote.hosts")
        try "10.0.0.7 fetched.example.test\n".write(to: source, atomically: true, encoding: .utf8)
        let tree: [[String: Any]] = [[
            "id": "r", "title": "R", "type": "remote", "on": false,
            "source": "url", "url": source.absoluteString, "refresh_interval": 0,
        ]]
        try await core.send("set_list", [tree])

        let first = try await core.json("refresh_remote_hosts", ["r"]) as? [String: Any]
        XCTAssertEqual(first?["success"] as? Bool, true)
        let fetched = try await core.call(String.self, "get_hosts_content", ["r"])
        XCTAssertEqual(fetched, "10.0.0.7 fetched.example.test\n")

        try FileManager.default.removeItem(at: source)
        let failed = try await core.json("refresh_remote_hosts", ["r"]) as? [String: Any]
        XCTAssertEqual(failed?["success"] as? Bool, false)
        let kept = try await core.call(String.self, "get_hosts_content", ["r"])
        XCTAssertEqual(kept, "10.0.0.7 fetched.example.test\n", "a failed refresh must keep the last good content")
    }

    /// Find/replace and apply-history commands cross the bridge with the same shapes the UI decodes.
    func testHistoryCommandsRoundTripThroughTheBridge() async throws {
        let core = try SwhCore(root: root.path)
        defer { core.close() }

        try await core.send("find_add_history", [["value": "needle", "is_regexp": false, "is_ignore_case": true]])
        let finds = try await core.call([FindHistoryEntry].self, "find_get_history")
        XCTAssertEqual(finds, [FindHistoryEntry(value: "needle", isRegexp: false, isIgnoreCase: true)])

        try await core.send("find_add_replace_history", ["replacement"])
        let replacements = try await core.call([String].self, "find_get_replace_history")
        XCTAssertEqual(replacements, ["replacement"])

        let records = try await core.call([ApplyRecord].self, "get_apply_history")
        XCTAssertEqual(records, [])
        let removed = try await core.call(Bool.self, "delete_apply_history_item", ["missing"])
        XCTAssertFalse(removed)

        let limit = try await core.json("update_apply_history_limit", [["limit": 20, "confirmation": NSNull()]]) as? [String: Any]
        XCTAssertEqual(limit?["confirmation_required"] as? Bool, false)
    }
}

