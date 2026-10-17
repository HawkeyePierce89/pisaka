import Foundation
@testable import PisakaCore
import XCTest

final class DiagnosticNavigationRuleTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/project/main.swift")

    private func diagnostic(at location: Int, _ severity: DiagnosticSeverity, length: Int = 3) -> Diagnostic {
        Diagnostic(
            range: NSRange(location: location, length: length),
            line: 0,
            severity: severity,
            message: "m",
            source: nil,
            fileURL: url
        )
    }

    /// Steps from `caret` `count` times in `direction`, each step starting at
    /// the previous landing point, as repeated presses do.
    private func walk(
        _ diagnostics: [Diagnostic],
        from caret: Int,
        _ direction: DiagnosticNavigationDirection,
        count: Int
    ) -> [Int?] {
        var position = caret
        var visited: [Int?] = []
        for _ in 0..<count {
            let target = DiagnosticNavigationRule.target(diagnostics: diagnostics, caret: position, direction: direction)
            visited.append(target)
            if let target { position = target }
        }
        return visited
    }

    func testErrorsAreTheOnlyStopsWhenAnyExistAndNextWraps() {
        let diagnostics = [
            diagnostic(at: 5, .warning),
            diagnostic(at: 40, .error),
            diagnostic(at: 20, .warning),
            diagnostic(at: 10, .error),
            diagnostic(at: 60, .hint),
        ]
        XCTAssertEqual(walk(diagnostics, from: 0, .next, count: 4), [10, 40, 10, 40])
    }

    func testWarningsOnlyCycleThroughEverySeverity() {
        let diagnostics = [
            diagnostic(at: 30, .warning),
            diagnostic(at: 8, .information),
            diagnostic(at: 15, .warning),
        ]
        XCTAssertEqual(walk(diagnostics, from: 0, .next, count: 4), [8, 15, 30, 8])
    }

    func testPreviousWrapsBackwards() {
        let diagnostics = [
            diagnostic(at: 30, .warning),
            diagnostic(at: 8, .warning),
            diagnostic(at: 15, .warning),
        ]
        XCTAssertEqual(walk(diagnostics, from: 20, .previous, count: 4), [15, 8, 30, 15])
    }

    func testPreviousSkipsWarningsWhenErrorsExist() {
        let diagnostics = [diagnostic(at: 8, .error), diagnostic(at: 15, .warning), diagnostic(at: 30, .error)]
        XCTAssertEqual(walk(diagnostics, from: 20, .previous, count: 3), [8, 30, 8])
    }

    func testDiagnosticsSharingAStartAreOneStop() {
        let diagnostics = [
            diagnostic(at: 12, .error, length: 1),
            diagnostic(at: 12, .error, length: 7),
            diagnostic(at: 25, .error),
        ]
        XCTAssertEqual(DiagnosticNavigationRule.stops(in: diagnostics), [12, 25])
        XCTAssertEqual(walk(diagnostics, from: 0, .next, count: 3), [12, 25, 12])
    }

    func testACaretSittingOnAStartMovesOn() {
        let diagnostics = [diagnostic(at: 12, .warning), diagnostic(at: 25, .warning)]
        XCTAssertEqual(DiagnosticNavigationRule.target(diagnostics: diagnostics, caret: 12, direction: .next), 25)
        XCTAssertEqual(DiagnosticNavigationRule.target(diagnostics: diagnostics, caret: 25, direction: .previous), 12)
    }

    func testASingleStopIsItsOwnWrap() {
        let diagnostics = [diagnostic(at: 12, .error)]
        XCTAssertEqual(DiagnosticNavigationRule.target(diagnostics: diagnostics, caret: 12, direction: .next), 12)
        XCTAssertEqual(DiagnosticNavigationRule.target(diagnostics: diagnostics, caret: 12, direction: .previous), 12)
    }

    func testAnEmptyListAnswersNil() {
        XCTAssertNil(DiagnosticNavigationRule.target(diagnostics: [], caret: 0, direction: .next))
        XCTAssertNil(DiagnosticNavigationRule.target(diagnostics: [], caret: 0, direction: .previous))
    }
}
