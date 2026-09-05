import XCTest
@testable import PisakaCore

final class FoldSeverityRuleTests: XCTestCase {
    private func lineStarts(for text: String) -> [Int] {
        LineStartIndex.offsets(in: text as NSString)
    }

    private func hiddenRange(
        in content: NSString,
        lineStarts: [Int],
        headerLine: Int,
        lastHiddenLine: Int
    ) -> NSRange {
        let headerRange = content.lineRange(for: NSRange(location: lineStarts[headerLine], length: 0))
        let lastRange = content.lineRange(for: NSRange(location: lineStarts[lastHiddenLine], length: 0))
        let loc = NSMaxRange(headerRange) - 1
        let end = NSMaxRange(lastRange) - 1
        return NSRange(location: loc, length: end - loc)
    }

    func testUnfoldedDocumentIsUnchanged() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let starts = lineStarts(for: text)
        let perLine: [DiagnosticSeverity?] = [.error, nil, .warning, nil, nil]
        let result = FoldSeverityRule.resolved(perLine, folded: FoldState(), lineStarts: starts)
        XCTAssertEqual(result, perLine)
    }

    func testFoldHidingNothingDiagnosedIsUnchanged() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: starts, headerLine: 1, lastHiddenLine: 3)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 1) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let perLine: [DiagnosticSeverity?] = [.error, nil, nil, nil, nil]
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result, perLine)
    }

    func testDiagnosticOnHeaderLineItselfIsKept() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: starts, headerLine: 0, lastHiddenLine: 2)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 0) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let perLine: [DiagnosticSeverity?] = [.warning, nil, nil, nil, nil]
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result[0], .warning)
    }

    func testHeaderRaisedToWorstAmongHidden() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: starts, headerLine: 0, lastHiddenLine: 3)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 0) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        // Header nil, hidden lines 1..3: line 2 warning, line 3 error
        let perLine: [DiagnosticSeverity?] = [nil, nil, .warning, .error, nil]
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result[0], .error)
        // Hidden lines left alone
        XCTAssertEqual(result[2], .warning)
        XCTAssertEqual(result[3], .error)
        XCTAssertNil(result[1])
    }

    func testHiddenLinesLeftAlone() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: starts, headerLine: 0, lastHiddenLine: 2)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 0) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let perLine: [DiagnosticSeverity?] = [nil, .error, .warning, nil, nil]
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        // Header should be error (worst of hidden)
        XCTAssertEqual(result[0], .error)
        // Hidden entries themselves unchanged
        XCTAssertEqual(result[1], .error)
        XCTAssertEqual(result[2], .warning)
    }

    func testNestedFoldsOuterShowsWorstOfEverythingInnerShowsOwn() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let outerHidden = hiddenRange(in: content, lineStarts: starts, headerLine: 0, lastHiddenLine: 8)
        let innerHidden = hiddenRange(in: content, lineStarts: starts, headerLine: 3, lastHiddenLine: 5)
        guard let outer = FoldRegion(hiddenRange: outerHidden, headerLine: 0),
              let inner = FoldRegion(hiddenRange: innerHidden, headerLine: 3) else {
            XCTFail("regions")
            return
        }
        let state = FoldState(regions: [outer, inner])
        // perLine: header 0 nil, inner header 3 warning, inner hidden 4 hint, outer hidden elsewhere error at line 7
        var perLine: [DiagnosticSeverity?] = Array(repeating: nil, count: starts.count)
        perLine[3] = .warning
        perLine[4] = .hint
        perLine[7] = .error
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        // Inner header should be max(warning, hint) = warning
        XCTAssertEqual(result[3], .warning)
        // Outer header should be max of everything outer hides: warning, hint, error => error
        XCTAssertEqual(result[0], .error)
        // Hidden lines unchanged
        XCTAssertEqual(result[4], .hint)
        XCTAssertEqual(result[7], .error)
    }

    func testNestedFoldInnerRaisedFromHiddenError() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let outerHidden = hiddenRange(in: content, lineStarts: starts, headerLine: 0, lastHiddenLine: 8)
        let innerHidden = hiddenRange(in: content, lineStarts: starts, headerLine: 3, lastHiddenLine: 5)
        guard let outer = FoldRegion(hiddenRange: outerHidden, headerLine: 0),
              let inner = FoldRegion(hiddenRange: innerHidden, headerLine: 3) else {
            XCTFail("regions")
            return
        }
        let state = FoldState(regions: [outer, inner])
        var perLine: [DiagnosticSeverity?] = Array(repeating: nil, count: starts.count)
        perLine[4] = .error
        // inner header nil, hidden has error => inner should become error
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result[3], .error)
        // outer should also be error because it hides line 4
        XCTAssertEqual(result[0], .error)
    }

    func testTies() {
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let starts = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: starts, headerLine: 0, lastHiddenLine: 3)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 0) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let perLine: [DiagnosticSeverity?] = [nil, .warning, .warning, nil, nil]
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result[0], .warning)
    }

    func testDegenerateEmptyLineTableAnswersInputUnchanged() {
        let perLine: [DiagnosticSeverity?] = [.error, .warning]
        let result = FoldSeverityRule.resolved(perLine, folded: FoldState(), lineStarts: [])
        XCTAssertEqual(result, perLine)
        // Empty perLine too
        let empty: [DiagnosticSeverity?] = []
        XCTAssertEqual(FoldSeverityRule.resolved(empty, folded: FoldState(), lineStarts: []), [])
    }

    func testDegenerateUnanchoredLineTableAnswersInputUnchanged() {
        let perLine: [DiagnosticSeverity?] = [.error, .warning, nil]
        // Not anchored at 0
        let starts = [2, 6, 10]
        let text = (1...5).map { "line \($0)" }.joined(separator: "\n")
        let content = text as NSString
        let lineStartsReal = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: lineStartsReal, headerLine: 0, lastHiddenLine: 2)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 0) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result, perLine)
    }

    func testDegenerateMismatchedCountsAnswersInputUnchanged() {
        let perLine: [DiagnosticSeverity?] = [.error, .warning]
        let starts = [0, 5, 10]
        let text = (1...3).map { _ in "x" }.joined(separator: "\n")
        let content = text as NSString
        let realStarts = lineStarts(for: text)
        let hidden = hiddenRange(in: content, lineStarts: realStarts, headerLine: 0, lastHiddenLine: 1)
        guard let region = FoldRegion(hiddenRange: hidden, headerLine: 0) else {
            XCTFail("region")
            return
        }
        let state = FoldState(regions: [region])
        let result = FoldSeverityRule.resolved(perLine, folded: state, lineStarts: starts)
        XCTAssertEqual(result, perLine)
    }
}
