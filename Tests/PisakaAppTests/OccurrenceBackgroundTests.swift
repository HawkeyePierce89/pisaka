#if os(macOS)
import AppKit
import PisakaCore
import XCTest
@testable import Pisaka

/// The occurrence, selection-match and tag-pair background layers, read off the
/// layout manager that paints them.
///
/// The editor's real TextKit 1 stack (`EditorLayoutHarness`), no window. What
/// it pins:
/// - the five background layers stack in one order, bottom to top: occurrences
///   (and selection matches), the tag pair, the bracket pair, the search
///   matches, the current search match — read as the colour left on a character
///   every layer covers, after each layer is added in turn;
/// - `clearBackgrounds(storageLength:)` drops the two new layers with the rest;
/// - an unchanged push is a no-op: the painted attribute is removed behind the
///   manager's back, and re-pushing the same input does not put it back;
/// - **AC4**: painting and clearing every layer registers no undo, leaves the
///   string as it was, and makes no character edit in the text storage. The
///   undo probe is shown to be live by a positive control that does register.
@MainActor
final class OccurrenceBackgroundTests: XCTestCase {
    private let text = "let value = value + value\n"
    private let theme = SyntaxTheme.shared

    // MARK: - Order

    func testTheLayersStackInTheirOneOrder() throws {
        let harness = makeHarness()
        let manager = harness.layoutManager
        let index = 5
        let cover = NSRange(location: 4, length: 5)

        manager.setOccurrenceRuns([.init(range: cover, kind: .read)])
        try assertBackground(harness, at: index, is: theme.nsOccurrenceReadBackground, "occurrence alone")

        manager.setTagRanges([cover])
        try assertBackground(harness, at: index, is: theme.nsTagMatchBackground, "tag over occurrence")

        manager.setPairRanges([NSRange(location: index, length: 1)])
        try assertBackground(harness, at: index, is: ChromePalette.nsColor(.bracketMatch), "pair over tag")

        manager.setSearchRanges([cover], current: nil)
        try assertBackground(harness, at: index, is: theme.nsSearchMatchBackground, "search over pair")

        manager.setSearchRanges([cover], current: cover)
        try assertBackground(harness, at: index, is: theme.nsCurrentSearchMatchBackground, "current over search")
    }

    /// The order holds on the other paint path too: a Neon-style write through
    /// `setTemporaryAttributes` re-applies the overlays over the written range.
    func testANeonWriteRepaintsInTheSameOrder() throws {
        let harness = makeHarness()
        let manager = harness.layoutManager
        let cover = NSRange(location: 4, length: 5)
        manager.setOccurrenceRuns([.init(range: cover, kind: .write)])
        manager.setTagRanges([NSRange(location: 6, length: 3)])

        manager.setTemporaryAttributes([.foregroundColor: NSColor.red], forCharacterRange: cover)
        try assertBackground(harness, at: 4, is: theme.nsOccurrenceWriteBackground, "occurrence beneath")
        try assertBackground(harness, at: 7, is: theme.nsTagMatchBackground, "tag on top")
    }

    func testEachOccurrenceKindPaintsItsOwnWash() throws {
        let harness = makeHarness()
        harness.layoutManager.setOccurrenceRuns([
            .init(range: NSRange(location: 20, length: 5), kind: .selectionMatch),
            .init(range: NSRange(location: 4, length: 5), kind: .write),
            .init(range: NSRange(location: 12, length: 5), kind: .read),
        ])
        try assertBackground(harness, at: 4, is: theme.nsOccurrenceWriteBackground, "write")
        try assertBackground(harness, at: 12, is: theme.nsOccurrenceReadBackground, "read")
        try assertBackground(harness, at: 20, is: theme.nsSelectionMatchBackground, "selection match")
        XCTAssertNil(background(harness, at: 10), "the gap between runs is painted")
    }

    func testClearingDropsEveryLayer() {
        let harness = makeHarness()
        paintEveryLayer(harness)
        harness.layoutManager.clearBackgrounds(storageLength: harness.textStorage.length)
        for index in 0..<harness.textStorage.length {
            XCTAssertNil(background(harness, at: index), "a background survives the clear at \(index)")
        }
    }

    func testEmptyPushesClearTheirLayer() {
        let harness = makeHarness()
        harness.layoutManager.setOccurrenceRuns([.init(range: NSRange(location: 4, length: 5), kind: .read)])
        harness.layoutManager.setTagRanges([NSRange(location: 12, length: 5)])
        harness.layoutManager.setOccurrenceRuns([])
        harness.layoutManager.setTagRanges([])
        XCTAssertNil(background(harness, at: 4))
        XCTAssertNil(background(harness, at: 12))
    }

    // MARK: - No-op on unchanged input

    func testAnUnchangedPushDoesNotRepaint() {
        let harness = makeHarness()
        let manager = harness.layoutManager
        let runs: [BracketOverlayLayoutManager.OccurrenceRun] = [
            .init(range: NSRange(location: 4, length: 5), kind: .read),
            .init(range: NSRange(location: 12, length: 5), kind: .write),
        ]
        let tags = [NSRange(location: 20, length: 5)]
        manager.setOccurrenceRuns(runs)
        manager.setTagRanges(tags)

        // Remove the paint behind the manager's back: a repaint would restore it.
        manager.removeTemporaryAttribute(
            .backgroundColor, forCharacterRange: NSRange(location: 0, length: harness.textStorage.length)
        )
        manager.setOccurrenceRuns(runs)
        manager.setTagRanges(tags)
        // The same runs in another order are the same set.
        manager.setOccurrenceRuns(runs.reversed())
        XCTAssertNil(background(harness, at: 4), "an unchanged occurrence push repainted")
        XCTAssertNil(background(harness, at: 20), "an unchanged tag push repainted")

        // And a changed push does repaint, so the probe can see a repaint at all.
        manager.setTagRanges([NSRange(location: 21, length: 4)])
        XCTAssertNotNil(background(harness, at: 4), "a changed push did not repaint")
    }

    // MARK: - AC4: a reader

    func testPaintingAndClearingIsNotAnEdit() throws {
        let harness = makeHarness()
        let probe = EditProbe(harness)
        paintEveryLayer(harness)
        harness.layoutManager.setOccurrenceRuns([.init(range: NSRange(location: 0, length: 3), kind: .read)])
        harness.layoutManager.clearBackgrounds(storageLength: harness.textStorage.length)

        XCTAssertEqual(harness.textView.string, text, "the string changed")
        XCTAssertFalse(probe.undoManager.canUndo, "painting registered an undo entry")
        XCTAssertFalse(probe.sawCharacterEdit, "painting edited the storage's characters")
        XCTAssertTrue(harness.textView.undoManager === probe.undoManager, "the probe's undo manager is not the view's")
    }

    /// The positive control for the probe above: a real edit is seen by both
    /// halves, so their silence there means something.
    func testTheEditProbeSeesARealEdit() {
        let harness = makeHarness()
        let probe = EditProbe(harness)
        probe.undoManager.groupsByEvent = false
        probe.undoManager.beginUndoGrouping()
        let range = NSRange(location: 0, length: 0)
        if harness.textView.shouldChangeText(in: range, replacementString: "x") {
            harness.textStorage.replaceCharacters(in: range, with: "x")
            harness.textView.didChangeText()
        }
        probe.undoManager.endUndoGrouping()
        XCTAssertTrue(probe.undoManager.canUndo, "the probe's undo manager never saw the edit")
        XCTAssertTrue(probe.sawCharacterEdit, "the probe never saw the character edit")
    }

    // MARK: - Harness

    /// Hands the text view a fixed undo manager and records every storage edit's
    /// mask.
    private final class EditProbe: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        private(set) var sawCharacterEdit = false
        private var observer: NSObjectProtocol?

        init(_ harness: EditorLayoutHarness) {
            super.init()
            harness.textView.allowsUndo = true
            harness.textView.delegate = self
            observer = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: harness.textStorage,
                queue: nil
            ) { [weak self] note in
                guard let storage = note.object as? NSTextStorage else { return }
                if storage.editedMask.contains(.editedCharacters) {
                    MainActor.assumeIsolated { self?.sawCharacterEdit = true }
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    private func makeHarness() -> EditorLayoutHarness {
        let harness = EditorLayoutHarness()
        harness.textView.string = text
        harness.layOut()
        return harness
    }

    private func paintEveryLayer(_ harness: EditorLayoutHarness) {
        let manager = harness.layoutManager
        manager.setOccurrenceRuns([
            .init(range: NSRange(location: 4, length: 5), kind: .write),
            .init(range: NSRange(location: 12, length: 5), kind: .read),
            .init(range: NSRange(location: 20, length: 5), kind: .selectionMatch),
        ])
        manager.setTagRanges([NSRange(location: 0, length: 3)])
        manager.setPairRanges([NSRange(location: 10, length: 1)])
        manager.setSearchRanges([NSRange(location: 12, length: 5)], current: NSRange(location: 20, length: 5))
    }

    private func background(_ harness: EditorLayoutHarness, at index: Int) -> NSColor? {
        harness.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    private func assertBackground(
        _ harness: EditorLayoutHarness,
        at index: Int,
        is expected: NSColor,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let painted = try XCTUnwrap(background(harness, at: index), "\(message): nothing painted", file: file, line: line)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(
                try rgb(painted, under: name), try rgb(expected, under: name),
                "\(message), \(name.rawValue)", file: file, line: line
            )
        }
    }

    private func rgb(_ color: NSColor, under name: NSAppearance.Name) throws -> UInt32 {
        var resolved = color
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        let srgb = try XCTUnwrap(resolved.usingColorSpace(.sRGB))
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(srgb.redComponent) << 16 | byte(srgb.greenComponent) << 8 | byte(srgb.blueComponent)
    }
}
#endif
