import AppKit
import SwiftUI
import XCTest
@testable import SwitchHostsNative

/// Renders the real views offscreen into PNG files for visual review. Set
/// SWH_SHOTS_DIR to a folder to write them; the tests are skipped otherwise.
/// The data comes from a temporary HOME, so the real data is not read or changed.
@MainActor
final class RenderTests: XCTestCase {
    private var home: URL!
    private var savedHome: String?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SWH_SHOTS_DIR"] != nil else {
            throw XCTSkip("SWH_SHOTS_DIR is not set")
        }
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("swh-render-\(UUID().uuidString)", isDirectory: true)
        let data = home.appendingPathComponent(".SwitchHosts")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("internal"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appendingPathComponent("entries"), withIntermediateDirectories: true)
        try Self.seedManifest.write(to: data.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try #"{"write_mode": ""}"#.write(to: data.appendingPathComponent("internal/config.json"), atomically: true, encoding: .utf8)
        try "# Host Database\n127.0.0.1 localhost\n10.0.1.5 api.example.test\n# 10.0.1.9 disabled.example.test\n\n10.0.0.8 staging.example.test\n".write(to: data.appendingPathComponent("entries/api.hosts"), atomically: true, encoding: .utf8)
        try "10.0.0.8 staging.example.test\n".write(to: data.appendingPathComponent("entries/staging.hosts"), atomically: true, encoding: .utf8)
        savedHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
    }

    override func tearDownWithError() throws {
        // Setup may have skipped before the temporary HOME was made.
        if let savedHome { setenv("HOME", savedHome, 1) }
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private static let seedManifest = """
    {"format": "switchhosts-data", "schemaVersion": 1, "root": [
      {"id": "web", "type": "local", "title": "前端站点", "on": false},
      {"id": "team", "type": "folder", "title": "团队环境", "on": false, "folder": {"mode": 0}, "children": [
        {"id": "dev", "type": "local", "title": "开发环境", "on": false},
        {"id": "api", "type": "local", "title": "API 服务", "on": false}
      ]},
      {"id": "staging", "type": "local", "title": "预发布", "on": false}
    ]}
    """

    private func render<V: View>(_ view: V, size: NSSize, name: String) throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWH_SHOTS_DIR"]!, isDirectory: true)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrame(NSRect(origin: .zero, size: size), display: true)
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("no bitmap for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func testRenderMainWindowWithAFolderSelected() async throws {
        let model = HostsModel()
        await model.start()
        await model.showSidebar(.folder("team"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try render(ContentView(model: model), size: NSSize(width: 1100, height: 640), name: "main-folder")
    }

    /// The editor's text view with its line-number gutter, rendered directly.
    /// (The SwiftUI-hosted editor does not lay out offscreen, so it is not used here.)
    func testRenderGutterBesideTheEditor() throws {
        let scroll = NSTextView.scrollableTextView()
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = (1...24).map { "10.0.0.\($0) host\($0).example.test" }.joined(separator: "\n")
        HighlightingEditor.highlight(textView)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(scrollView: scroll, textView: textView)
        let size = NSSize(width: 420, height: 360)
        scroll.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = scroll
        textView.textColor = .labelColor
        textView.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
        }
        let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWH_SHOTS_DIR"]!, isDirectory: true)
        try png.write(to: dir.appendingPathComponent("gutter.png"))
    }

    func testRenderTrayCompactList() async throws {
        let model = HostsModel()
        await model.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        try render(MenuBarView(model: model), size: NSSize(width: 240, height: 260), name: "tray-compact")
    }

    func testRenderPreferencesGeneralTab() async throws {
        let model = HostsModel()
        await model.start()
        try render(PreferencesView(model: model), size: NSSize(width: 560, height: 540), name: "preferences")
    }
}

/// Renders the compact tray list with ImageRenderer, which draws SwiftUI text
/// without a window. This checks the list's content, not the real status item.
@MainActor
final class ImageRendererTests: XCTestCase {
    func testCompactTrayListRendersItsLabels() throws {
        guard let dir = ProcessInfo.processInfo.environment["SWH_SHOTS_DIR"] else {
            throw XCTSkip("SWH_SHOTS_DIR is not set")
        }
        let model = HostsModel()
        let renderer = ImageRenderer(content: MenuBarView(model: model).frame(width: 240, height: 200))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tray-compact-renderer.png"))
    }
}
