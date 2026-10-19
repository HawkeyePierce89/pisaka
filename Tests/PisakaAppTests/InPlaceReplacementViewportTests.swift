#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The in-place replacement rule of `CodeEditorView.updateNSView`, which
/// `swift test` cannot see because it lives between a real `NSTextView` and the
/// SwiftUI update that swaps its string: when the **displayed** tab's buffer is
/// replaced in place (here `WorkspaceModel.reloadFromDisk(id:)`, the path the
/// watcher, activation, Reload, a post-operation resync, a merge apply and a
/// Local History restore all reach), the caret and the scroll anchor captured
/// off the live view before the swap are re-applied after it, clamped to the
/// new text by `EditorViewport.clamped(toLength:)`.
///
/// - an edit far below the caret leaves the selection and the top character
///   exactly where they were;
/// - a selection crossing a shrunken new end is truncated to it, and a caret
///   past a shrunken new end lands at the new end, with nothing raised.
///
/// A real file in a throwaway directory, read through the real `FileService`
/// into a real `WorkspaceModel`, shown by the real `CodeEditorView` hosted in an
/// offscreen window. The swap is awaited causally — a predicate on the text
/// view's own string — never through a clock.
///
/// Seen failing first: with the Task 1 change to `CodeEditorView.swift`
/// reverted, both cases fail — case 1's caret lands at the end of the new text
/// (`{2058, 0}` for `{16, 0}`) and its top character moves (783 for 303); case
/// 2's crossing selection collapses to the end (`{151, 0}` for `{63, 88}`) —
/// and both pass with it applied. Case 2's bare caret alone could not tell the
/// two apart (the swap also leaves it at the end), which is why it rides behind
/// the crossing selection rather than standing as the case.
@MainActor
final class InPlaceReplacementViewportTests: XCTestCase {
    private var directory: URL!
    private var window: NSWindow?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InPlaceReplacementViewportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.close()
        window = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// `count` lines, `line 1` … `line count`, each newline-terminated.
    private func lines(_ count: Int) -> String {
        (1...count).map { "line \($0)\n" }.joined()
    }

    /// The UTF-16 offset of the start of 1-based `line` in `text`.
    private func offset(ofLine line: Int, in text: String) -> Int {
        let ns = text as NSString
        var location = 0
        for _ in 1..<line {
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
        }
        return location
    }

    /// Open `text` as a real file, host its editor offscreen, and hand back the
    /// model, the tab and the editor's text view once its string is installed.
    private func hostEditor(_ text: String) throws -> HostedEditor {
        let url = directory.appendingPathComponent("file.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(fileService: FileService())
        let file = try model.open(url: url)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorHost(model: model, id: file.id))
        self.window = window
        window.contentView?.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(
            Self.firstTextView(in: try XCTUnwrap(window.contentView)),
            "the hosted editor built no text view"
        )
        waitUntil { textView.string == text }
        let coordinator = try XCTUnwrap(
            textView.delegate as? CodeEditorView.Coordinator,
            "the text view's delegate is not the editor's coordinator"
        )
        return HostedEditor(model: model, file: file, url: url, textView: textView, coordinator: coordinator)
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    /// The causal rendezvous: wait for `condition` to hold, failing loudly on
    /// timeout rather than passing vacuously.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) {
        let arrived = expectation(for: NSPredicate { _, _ in
            MainActor.assumeIsolated { condition() }
        }, evaluatedWith: nil)
        wait(for: [arrived], timeout: 5)
    }

    func testAnEditFarBelowTheCaretKeepsTheSelectionAndTheTopCharacter() throws {
        let original = lines(240)
        let hosted = try hostEditor(original)
        let (model, file, url, textView, coordinator) =
            (hosted.model, hosted.file, hosted.url, hosted.textView, hosted.coordinator)

        let caret = NSRange(location: offset(ofLine: 3, in: original) + 2, length: 0)
        textView.setSelectedRange(caret)
        coordinator.scrollAnchor(to: offset(ofLine: 40, in: original))
        let before = try XCTUnwrap(coordinator.captureViewport())
        XCTAssertEqual(before.selection, caret)
        XCTAssertGreaterThan(before.topCharacterOffset, 0, "the page never scrolled, so the anchor proves nothing")

        let edited = original.replacingOccurrences(of: "line 200\n", with: "edited on disk\n")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.reloadFromDisk(id: file.id))
        waitUntil { textView.string == edited }

        XCTAssertEqual(textView.selectedRange(), caret, "the caret moved across an in-place reload")
        XCTAssertEqual(
            coordinator.captureViewport()?.topCharacterOffset, before.topCharacterOffset,
            "the top character moved across an in-place reload"
        )
    }

    func testASelectionCrossingAShrunkenEndIsTruncatedAndACaretPastItLandsAtTheEnd() throws {
        let original = lines(240)
        let hosted = try hostEditor(original)
        let (model, file, url, textView) = (hosted.model, hosted.file, hosted.url, hosted.textView)

        // A selection from line 10 to near the old end: the new text keeps its
        // start and loses its end.
        let start = offset(ofLine: 10, in: original)
        let length = (original as NSString).length
        textView.setSelectedRange(NSRange(location: start, length: length - 3 - start))

        let shorter = lines(20)
        let newLength = (shorter as NSString).length
        try shorter.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.reloadFromDisk(id: file.id))
        waitUntil { textView.string == shorter }
        XCTAssertEqual(
            textView.selectedRange(), NSRange(location: start, length: newLength - start),
            "a selection crossing the new end was not truncated to it"
        )

        // A bare caret past a shrunken end lands at the new end, and nothing raises.
        textView.setSelectedRange(NSRange(location: newLength - 3, length: 0))
        let shortest = lines(5)
        try shortest.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(model.reloadFromDisk(id: file.id))
        waitUntil { textView.string == shortest }
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (shortest as NSString).length, length: 0))
    }
}

/// What `hostEditor` hands back: the model and tab behind the editor, the
/// file on disk, and the editor's own text view and coordinator.
private struct HostedEditor {
    let model: WorkspaceModel
    let file: OpenFile
    let url: URL
    let textView: NSTextView
    let coordinator: CodeEditorView.Coordinator
}

/// The smallest observer of a `WorkspaceModel` that shows one tab the way
/// `ContentView` does: the buffer through a binding, and the replacement token
/// that tells an in-place replacement from a keystroke.
private struct EditorHost: View {
    @ObservedObject var model: WorkspaceModel
    let id: UUID

    var body: some View {
        CodeEditorView(
            fileID: id,
            fileName: "file.txt",
            openFileIDs: Set(model.openFiles.map(\.id)),
            externalTextRevision: model.textReplacementRevision(for: id),
            text: Binding(
                get: { model.openFiles.first { $0.id == id }?.text ?? "" },
                set: { model.updateText($0, for: id) }
            ),
            fontSize: 13,
            fontFamily: nil,
            completionEnabled: false,
            indentLevelHighlightingEnabled: false,
            interfaceMetrics: InterfaceMetrics(scale: 1),
            editorConfig: EditorConfigModel(fileService: FileService())
        )
    }
}
#endif
