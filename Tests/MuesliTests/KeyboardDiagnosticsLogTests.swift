import XCTest
@testable import Muesli

final class KeyboardDiagnosticsLogTests: XCTestCase {
    func testShortLogIsUnchanged() {
        let text = "a\nb\n"
        XCTAssertEqual(KeyboardDiagnosticsLog.newestLines(of: text, fittingIn: 1_000), text)
    }

    func testLongLogKeepsNewestEntriesInOrder() {
        let lines = (1...2_000).map { "2026-11-26T06:00:\(String(format: "%04d", $0))Z\tMuesliDevKeyboard\tevent=\($0)" }
        let text = lines.joined(separator: "\n") + "\n"

        let trimmed = KeyboardDiagnosticsLog.newestLines(of: text, fittingIn: 60_000)

        XCTAssertLessThanOrEqual(trimmed.utf8.count, 60_000)
        XCTAssertTrue(trimmed.hasSuffix("event=2000\n"), "the newest entry survives")
        let kept = trimmed.split(separator: "\n").dropFirst()
        XCTAssertEqual(kept.last.map(String.init), lines.last)
        XCTAssertTrue(trimmed.hasPrefix("(\(2_000 - kept.count) older entries omitted)\n"))
        XCTAssertEqual(Array(kept.map(String.init)), Array(lines.suffix(kept.count)), "order is preserved")
    }
}
