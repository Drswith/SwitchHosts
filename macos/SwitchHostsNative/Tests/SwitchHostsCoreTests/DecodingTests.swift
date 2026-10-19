import Foundation
import XCTest
@testable import SwitchHostsCore

/// The shapes the core returns for the newer commands must decode as the UI expects.
final class DecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testDataDirStatusReadsARecoveryWithANullPath() throws {
        let status = try decode(DataDirStatus.self, """
        {"active_dir": "/a", "default_dir": "/d", "can_reset": true,
         "recovery": {"kind": "invalid", "path": null}}
        """)
        XCTAssertEqual(status.activeDir, "/a")
        XCTAssertEqual(status.defaultDir, "/d")
        XCTAssertTrue(status.canReset)
        XCTAssertEqual(status.recoveryKind, "invalid")
    }

    func testDataDirStatusWithoutRecovery() throws {
        let status = try decode(DataDirStatus.self, """
        {"active_dir": "/a", "default_dir": "/d", "can_reset": false, "recovery": null}
        """)
        XCTAssertNil(status.recoveryKind)
        XCTAssertFalse(status.canReset)
    }

    func testDataDirPlanReadsTheKindAndFlags() throws {
        let plan = try decode(DataDirPlan.self, """
        {"kind": "custom", "data_dir": "/x/SwitchHosts.data", "is_empty": true, "is_same_as_current": false}
        """)
        XCTAssertEqual(plan.dataDir, "/x/SwitchHosts.data")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.isSameAsCurrent)
        XCTAssertFalse(plan.isDefault)
    }

    func testCommandRunReadsTheUnderscoredIdAndTimestamp() throws {
        let run = try decode(CommandRun.self, """
        {"_id": "cmd_1", "success": false, "stdout": "", "stderr": "boom", "add_time_ms": 1700000000000}
        """)
        XCTAssertEqual(run.id, "cmd_1")
        XCTAssertFalse(run.success)
        XCTAssertEqual(run.stderr, "boom")
        XCTAssertEqual(run.date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testApplyRecordReadsContentAndTimestamp() throws {
        let record = try decode(ApplyRecord.self, """
        {"id": "h1", "content": "127.0.0.1 localhost\\n", "add_time_ms": 1700000000000, "label": null}
        """)
        XCTAssertEqual(record.id, "h1")
        XCTAssertEqual(record.content, "127.0.0.1 localhost\n")
    }

    func testFolderFieldsDecodeFromTheTree() throws {
        let node = try decode(HostsNode.self, """
        {"id": "f", "title": "F", "type": "folder", "on": false, "children": [], "is_collapsed": true, "folder_mode": 1}
        """)
        XCTAssertTrue(node.isClosed)
        XCTAssertEqual(node.folderMode, 1)
    }

    func testDataDirStatusKeepsTheMissingFolderPath() throws {
        let status = try decode(DataDirStatus.self, """
        {"active_dir": "/a", "default_dir": "/d", "can_reset": true,
         "recovery": {"kind": "missing", "path": "/Volumes/Gone/SwitchHosts"}}
        """)
        XCTAssertEqual(status.recoveryKind, "missing")
        XCTAssertEqual(status.recoveryPath, "/Volumes/Gone/SwitchHosts")
    }

    func testGroupsReadTheirIncludedIdsAndAreNotEditable() throws {
        let group = try decode(HostsNode.self, """
        {"id": "g", "title": "G", "type": "group", "on": false, "include": ["a", "b"]}
        """)
        XCTAssertTrue(group.isGroup)
        XCTAssertFalse(group.isLocal, "only local entries are edited by hand")
        XCTAssertEqual(group.include, ["a", "b"])

        let untyped = try decode(HostsNode.self, #"{"id": "x", "title": "X"}"#)
        XCTAssertTrue(untyped.isLocal, "a missing type is local, as in older data")
    }

    func testFindPositionsCarryTheTextAroundTheMatch() throws {
        let item = try decode(FindItem.self, """
        {"item_id": "r", "item_title": "R", "item_type": "remote", "positions": [
          {"start": 4, "end": 8, "line": 1, "line_pos": 4, "end_line": 1, "end_line_pos": 8,
           "before": "127.", "match": "0.0.", "after": "1 a.test"}]}
        """)
        XCTAssertTrue(item.isReadOnly, "only local entries can be replaced in")
        let position = try XCTUnwrap(item.positions.first)
        XCTAssertEqual(position.line, 1, "the core counts lines from 1")
        XCTAssertEqual(position.before + position.match + position.after, "127.0.0.1 a.test")

        let local = try decode(FindItem.self, """
        {"item_id": "l", "item_title": "L", "item_type": "local",
         "positions": [{"start": 0, "end": 1, "line": 3, "match": "x"}]}
        """)
        XCTAssertFalse(local.isReadOnly)
        XCTAssertEqual(local.positions.first?.before, "", "older results without context still decode")
    }
}
