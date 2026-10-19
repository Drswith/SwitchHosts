import Foundation
import XCTest
@testable import SwitchHostsCore

final class CoreTextTests: XCTestCase {
    /// The Chinese strings the app ships. Tests read the file, since the test
    /// bundle has no app localizations.
    private func chineseStrings() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SwitchHostsNative/Resources/zh-Hans.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let entry = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";"#)
        var strings: [String: String] = [:]
        let whole = NSRange(location: 0, length: (text as NSString).length)
        for match in entry.matches(in: text, range: whole) {
            let key = (text as NSString).substring(with: match.range(at: 1))
            let value = (text as NSString).substring(with: match.range(at: 2))
            strings[key.replacingOccurrences(of: "\\\"", with: "\"")] = value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return strings
    }

    func testMessagesWithoutAValueKeepTheirEnglishTextWhenUntranslated() {
        XCTAssertEqual(CoreText.localized("an untranslated message"), "an untranslated message")
        XCTAssertEqual(SwhError.command("write mode is not set").errorDescription, "write mode is not set")
    }

    func testTemplatesFillTheirValuesInOrder() {
        XCTAssertEqual(CoreText.localized("io error at /etc/hosts: denied"), "io error at /etc/hosts: denied")
        XCTAssertEqual(
            CoreText.localized("response body too large: 900 bytes exceeds limit of 500 bytes"),
            "response body too large: 900 bytes exceeds limit of 500 bytes"
        )
        XCTAssertEqual(CoreText.localized("error_404"), "Server returned HTTP 404.")
    }

    /// Every template's Chinese text has as many slots as its pattern has values,
    /// so a translation can never drop or swap a value.
    func testEveryTemplateHasAChineseTextWithTheSameSlots() throws {
        let strings = try chineseStrings()
        for template in CoreText.templates {
            let groups = template.pattern.filter { $0 == "(" }.count
            let slots = template.key.components(separatedBy: "%@").count - 1
            XCTAssertEqual(slots, groups, "English key slots for \(template.pattern)")
            let chinese = try XCTUnwrap(strings[template.key], "missing translation for \(template.key)")
            let chineseSlots = chinese.components(separatedBy: "%@").count - 1
            XCTAssertEqual(chineseSlots, groups, "Chinese slots for \(template.key)")
        }
    }

    func testCommonFixedMessagesHaveChineseText() throws {
        let strings = try chineseStrings()
        let fixed = [
            "write mode is not set",
            "hosts entry not found",
            "system hosts changed since the apply",
            "cancelled",
            "invalid_data",
            "parse_error",
            "new_version",
            "DNS query timed out. Please retry.",
            "Could not connect to the server. Check the remote URL, network connection and proxy settings.",
            "Invalid proxy settings. Check the proxy protocol, host and port.",
            "Some domains could not be resolved. Previous addresses were kept where available.",
        ]
        for message in fixed {
            XCTAssertNotNil(strings[message], "missing translation for \(message)")
        }
    }
}
