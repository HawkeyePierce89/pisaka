#if os(macOS)
import XCTest
@testable import Pisaka

@MainActor
final class FoldLayoutTests: XCTestCase {
    /// A document long enough to produce an extra line fragment on
    /// `textView.string = text` — the shape that triggers the re-entrant
    /// typesetter allocation described in the plan's Overview.
    private let firstDocument = (0..<50).map { "line \($0) — the quick brown fox jumps over the lazy dog" }.joined(separator: "\n")
    private let secondDocument = (0..<50).map { "replaced \($0) — lorem ipsum dolor sit amet consectetur" }.joined(separator: "\n")

    func testReplacingDocumentWithoutFoldSurvivesLayout() {
        let harness = EditorLayoutHarness()
        harness.textView.string = firstDocument
        harness.layOut()
        // Exactly as updateNSView's content-replaced branch does: assign string,
        // then lay out again.
        harness.textView.string = secondDocument
        harness.layOut()
        XCTAssertEqual(harness.textView.string, secondDocument)
        XCTAssertGreaterThan(harness.layoutManager.numberOfGlyphs, 0)
    }

    func testReplacingDocumentWithFoldInstalledSurvivesLayout() {
        let harness = EditorLayoutHarness()
        harness.textView.string = firstDocument
        harness.layOut()
        // Install a fold before the swap — the second case the plan requires.
        let foldRange = NSRange(location: 0, length: 20)
        harness.layoutManager.setFoldedRanges([foldRange])
        harness.layOut()
        harness.textView.string = secondDocument
        harness.layOut()
        XCTAssertEqual(harness.textView.string, secondDocument)
        XCTAssertGreaterThan(harness.layoutManager.numberOfGlyphs, 0)
    }

    func testFoldingTypesetterSupportsObjCInit() {
        // Diagnosis from the plan: a Swift NSATSTypesetter subclass with only
        // a custom designated initializer traps when allocated through
        // Objective-C `init` — TextKit does exactly that during re-entrant
        // layout. Before the fix this traps with "Use of unimplemented
        // initializer 'init()'" — the EXC_BREAKPOINT in the report.
        let cls: AnyClass = FoldingTypesetter.self
        guard let nsCls = cls as? NSObject.Type else {
            XCTFail("FoldingTypesetter is not an NSObject subclass")
            return
        }
        let instance = nsCls.init()
        XCTAssertTrue(instance is FoldingTypesetter)
        // And it must answer control characters without crashing when it has no
        // manager (the second instance TextKit creates has no folded set).
        guard let typesetter = instance as? FoldingTypesetter else {
            XCTFail("instance is not a FoldingTypesetter")
            return
        }
        _ = typesetter.actionForControlCharacter(at: 0)
    }
}
#endif
