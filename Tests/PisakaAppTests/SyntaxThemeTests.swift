#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import PisakaCore
@testable import Pisaka

/// The code zone's colour table, pinned component by component.
///
/// `SyntaxTheme.table` is the one place a syntax colour is spelled, and nothing
/// in the product reads a value back out of it, so no compiler and no other
/// suite can see a digit transposed, a light value written on the dark side or a
/// row silently dropped. The table is therefore written out a second time here
/// and the two are compared: the duplication is the test.
///
/// The theme lives in the app target (colour is the view layer's business;
/// `PisakaCore` stays colour-free), so these assertions run in the app-layer
/// bundle rather than in `swift test`, mirroring `ChromePaletteTests`.
final class SyntaxThemeTests: XCTestCase {

    /// The table, restated. One row per `SyntaxTokenKind`. Every entry is opaque
    /// — nothing in this table is a wash — which the suite asserts rather than
    /// assumes.
    private static let expected: [SyntaxTokenKind: (dark: UInt32, light: UInt32)] = [
        .keyword: (0xB48EAD, 0x8250B0),
        .string: (0x9DB97B, 0x4F7942),
        .comment: (0x6B6E76, 0x8A8A90),
        .number: (0xC9976C, 0xA5652D),
        .type: (0x6A9FB5, 0x2B6A83),
        .function: (0x7AA6DA, 0x2F5FA8),
        .variable: (0xDFE1E5, 0x1D1D1F),
        .constant: (0xC9976C, 0xA5652D),
        .operator: (0xA0A3AA, 0x6E6E73),
        .punctuation: (0xA0A3AA, 0x6E6E73),
        .property: (0x7FA8A0, 0x2F6B63),
        .parameter: (0xDFE1E5, 0x1D1D1F),
        .label: (0x4F8DFF, 0x2F6FE0),
        .plain: (0xDFE1E5, 0x1D1D1F),
    ]

    // MARK: - Helpers

    /// The sRGB components of a concrete colour, as the 0...255 integers a hex
    /// literal is written in, plus its alpha.
    private func components(_ color: NSColor) throws -> (r: Int, g: Int, b: Int, alpha: CGFloat) {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB), "the colour is not representable in sRGB")
        return (
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded()),
            srgb.alphaComponent
        )
    }

    private func assertComponents(
        _ color: NSColor,
        equal rgb: UInt32,
        _ message: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try components(color)
        XCTAssertEqual(actual.r, Int((rgb >> 16) & 0xFF), "\(message()) — red", file: file, line: line)
        XCTAssertEqual(actual.g, Int((rgb >> 8) & 0xFF), "\(message()) — green", file: file, line: line)
        XCTAssertEqual(actual.b, Int(rgb & 0xFF), "\(message()) — blue", file: file, line: line)
        XCTAssertEqual(actual.alpha, 1, accuracy: 0.002, "\(message()) — alpha", file: file, line: line)
    }

    /// A restated row as the `#rrggbb` string the preview's CSS carries it in —
    /// lower case, three components, alpha dropped, which is the one spelling
    /// `SyntaxTheme.cssColorString(for:)` produces and the one the domain layer's
    /// own tables are written in.
    private func cssString(_ rgb: UInt32) -> String {
        String(
            format: "#%02x%02x%02x",
            Int((rgb >> 16) & 0xFF),
            Int((rgb >> 8) & 0xFF),
            Int(rgb & 0xFF)
        )
    }

    /// Resolves a dynamic colour the way AppKit does when it draws inside a
    /// window carrying that appearance.
    private func resolved(_ color: NSColor, under name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            // Asking a dynamic colour for a concrete colour space is what forces
            // it through its appearance closure; inside this block the current
            // drawing appearance is the one named.
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    // MARK: - The two value sets

    func testEveryTokenKindResolvesToItsTabledValueInBothAppearances() throws {
        // The restated table is complete: a kind added to Core without a row here
        // fails before any value is compared.
        XCTAssertEqual(Set(Self.expected.keys), Set(SyntaxTokenKind.allCases))

        for kind in SyntaxTokenKind.allCases {
            let row = try XCTUnwrap(Self.expected[kind], "\(kind) has no expected row")
            let colour = SyntaxTheme.shared.nsColor(for: kind)
            try assertComponents(resolved(colour, under: .darkAqua), equal: row.dark, "\(kind), dark")
            try assertComponents(resolved(colour, under: .aqua), equal: row.light, "\(kind), light")
        }
    }

    // MARK: - The rule

    /// No token kind resolves to a system semantic colour, in either appearance.
    ///
    /// The defect this exists for is a **value**, not an appearance: a system
    /// colour resolves against the window's appearance exactly as a table row
    /// does (the Theme preference is applied as `.preferredColorScheme` at the
    /// window root, which sets that appearance), so a kind left on one still
    /// follows the preference — it just carries the platform's value instead of
    /// the design's, a step off every row beside it. The rule is about that
    /// property, not about today's numbers — a later palette change keeps it, and
    /// a row quietly replaced by `.labelColor` breaks it.
    func testNoTokenKindResolvesToASystemSemanticColour() throws {
        let systemColours: [(name: String, colour: NSColor)] = [
            ("labelColor", .labelColor),
            ("secondaryLabelColor", .secondaryLabelColor),
            ("tertiaryLabelColor", .tertiaryLabelColor),
            ("textColor", .textColor),
        ]
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            for system in systemColours {
                let systemComponents = try components(resolved(system.colour, under: name))
                for kind in SyntaxTokenKind.allCases {
                    let kindComponents = try components(
                        resolved(SyntaxTheme.shared.nsColor(for: kind), under: name)
                    )
                    XCTAssertFalse(
                        kindComponents.r == systemComponents.r
                            && kindComponents.g == systemComponents.g
                            && kindComponents.b == systemComponents.b
                            && abs(kindComponents.alpha - systemComponents.alpha) < 0.002,
                        "\(kind) resolves to \(system.name) under \(name.rawValue) — "
                            + "a system colour carries the platform's value, not the design's"
                    )
                }
            }
        }
    }

    // MARK: - The fallback

    /// The fallback constant, asserted directly — no call to `color(for:)` can
    /// reach it — beside the statement of *why* that is so: the table is total
    /// over the closed `SyntaxTokenKind`, so there is no unmapped kind to ask
    /// with. The two sentences are one test because they are read together.
    func testThePlainTextFallbackIsThePlainRowAndIsUnreachableWhileTheTableIsTotal() throws {
        let row = try XCTUnwrap(Self.expected[.plain])
        try assertComponents(resolved(SyntaxTheme.plainText, under: .darkAqua), equal: row.dark, "plainText, dark")
        try assertComponents(resolved(SyntaxTheme.plainText, under: .aqua), equal: row.light, "plainText, light")

        // Why the constant has to be asserted directly: the table names every
        // kind, so `color(for:)` never falls through to it.
        XCTAssertEqual(Set(SyntaxTheme.table.keys), Set(SyntaxTokenKind.allCases))
    }

    // MARK: - The preview seam

    /// The palette actually reaches the preview page.
    ///
    /// What it pins: for each appearance, `markdownPreviewTheme(prefersDark:)`
    /// carries every token kind's colour, equal to the CSS spelling of *this
    /// suite's own restated row* — so the assertion is against the values the
    /// design states, not against whatever the production table happens to hold.
    /// A derivation that is wrong, partial, or resolved under the other
    /// appearance fails here, and so does an edit to `SyntaxTheme.table` not
    /// carried into this suite's restated rows.
    ///
    /// What it cannot see, precisely: the domain layer's own
    /// `MarkdownPreviewTheme.light`/`.dark` `codeColors`. The derived theme is
    /// built entirely from `table` and `withCodeColors(_:)` replaces the block
    /// wholesale, so Core's copy is never read here and could go stale with this
    /// assertion green. That copy is compared against the same restated rows by
    /// `testTheDomainLayersRestatedCodeColoursEqualTheEditorTable`; the two tests
    /// together are what make "the two copies state the same values" true.
    ///
    /// What neither can see: the derivation being deleted while the editor's
    /// table and the domain layer's restated one agree — the fall-back value is
    /// then correct by accident. Nothing that reads values can see that.
    ///
    /// Entries are read as `codeColors[kind]` through `XCTUnwrap` rather than
    /// through `color(for:)`, so a missing kind fails instead of falling through
    /// to the theme's body-text colour and comparing equal by accident.
    func testThePreviewThemeCarriesTheEditorsPaletteInBothAppearances() throws {
        for prefersDark in [true, false] {
            let derived = SyntaxTheme.shared.markdownPreviewTheme(prefersDark: prefersDark)
            let base = prefersDark ? MarkdownPreviewTheme.dark : MarkdownPreviewTheme.light

            for kind in SyntaxTokenKind.allCases {
                let row = try XCTUnwrap(Self.expected[kind], "\(kind) has no expected row")
                let wanted = cssString(prefersDark ? row.dark : row.light)
                let carried = try XCTUnwrap(
                    derived.codeColors[kind],
                    "\(kind) has no entry in the derived theme (prefersDark: \(prefersDark))"
                )
                XCTAssertEqual(carried, wanted, "\(kind), prefersDark: \(prefersDark)")
            }

            // The derivation overwrites code colours and nothing else: the page's
            // chrome is shared with the other document surface in the window and
            // stays the domain layer's.
            XCTAssertEqual(derived.background, base.background)
            XCTAssertEqual(derived.text, base.text)
            XCTAssertEqual(derived.secondaryText, base.secondaryText)
            XCTAssertEqual(derived.link, base.link)
            XCTAssertEqual(derived.codeBackground, base.codeBackground)
            XCTAssertEqual(derived.border, base.border)
            XCTAssertEqual(derived.tableBorder, base.tableBorder)
            XCTAssertEqual(derived.colorScheme, base.colorScheme)
        }
    }

    /// The domain layer's second copy of the code palette, compared entry for
    /// entry with the editor's.
    ///
    /// `MarkdownPreviewTheme.light`/`.dark` each carry a full `codeColors` block
    /// so `PisakaCore` has a complete theme to test and to fall back on. Nothing
    /// on macOS reads those entries — the app overwrites the whole block from
    /// `SyntaxTheme.table` — so a palette edit made on the editor's side alone
    /// leaves them stale with every screen correct and, before this test, every
    /// gate green. That is the state the branch set out to remove, and only an
    /// assertion can see it.
    ///
    /// The comparison is against this suite's own restated rows rather than
    /// against `table` read back at run time, for the reason the rest of the file
    /// gives: the restated rows are the design's values, and they are tied to the
    /// production table by
    /// `testEveryTokenKindResolvesToItsTabledValueInBothAppearances`. Editing
    /// `table` and the restated row together — the correct way to change the
    /// palette — therefore fails *here* until Core's copy follows.
    ///
    /// It lives in the app bundle because `PisakaCore` cannot see `SyntaxTheme`
    /// at all: colour is the view layer's business, and the domain layer is the
    /// side holding the copy.
    ///
    /// What it cannot see: the chrome entries beside `codeColors`, which are not
    /// the editor's to state and have no counterpart to compare against.
    func testTheDomainLayersRestatedCodeColoursEqualTheEditorTable() throws {
        for prefersDark in [true, false] {
            let theme = prefersDark ? MarkdownPreviewTheme.dark : MarkdownPreviewTheme.light

            // The block is complete on Core's side too: a kind added with no row
            // there fails before any value is compared.
            XCTAssertEqual(
                Set(theme.codeColors.keys),
                Set(SyntaxTokenKind.allCases),
                "MarkdownPreviewTheme.\(prefersDark ? "dark" : "light").codeColors does not name every token kind"
            )

            for kind in SyntaxTokenKind.allCases {
                let row = try XCTUnwrap(Self.expected[kind], "\(kind) has no expected row")
                let stated = try XCTUnwrap(
                    theme.codeColors[kind],
                    "\(kind) has no entry in MarkdownPreviewTheme.\(prefersDark ? "dark" : "light")"
                )
                XCTAssertEqual(
                    stated,
                    cssString(prefersDark ? row.dark : row.light),
                    "\(kind), prefersDark: \(prefersDark) — the domain layer's copy has gone stale "
                        + "against the editor's table"
                )
            }
        }
    }

    // MARK: - Uncovered text

    /// The two sites that give a character no capture covers its colour, each
    /// asserted at the site.
    ///
    /// What it pins: `CodeEditorView.applyBaseTypography(to:)` leaves a fresh
    /// text view's `textColor` on the `.plain` row in both appearances, and the
    /// no-grammar reset path — `Coordinator.updateHighlighter(for:language:contentReplaced:)`
    /// with no language — writes that same row over the whole storage. Both are
    /// read back off the object they wrote to, so deleting either assignment
    /// fails here even though `SyntaxTheme.shared.color(for: .plain)` keeps
    /// resolving correctly. That expression's own value is pinned by
    /// `testEveryTokenKindResolvesToItsTabledValueInBothAppearances`; asserting
    /// it a second time here would have pinned no site at all, which is what this
    /// test previously did.
    ///
    /// What it cannot see: a *third* surface added later that gives uncovered
    /// text a colour of its own. The set of views attaching the highlighter is
    /// `SyntaxBaseForegroundGatingTests`' subject, by set equality; this test
    /// knows only about the editor's two.
    ///
    /// The value asserted is this suite's own restated `.plain` row, not
    /// whatever the production table holds, so a palette edit made on one side
    /// only fails rather than agreeing with itself.
    @MainActor
    func testUncoveredTextReadsThePlainRowInBothAppearances() throws {
        let row = try XCTUnwrap(Self.expected[.plain])

        // Site one: the base typography every text view starts from.
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let editor = CodeEditorView(
            fileID: UUID(),
            fileName: "Untitled",
            openFileIDs: [],
            text: binding,
            fontSize: 13,
            completionEnabled: false,
            indentLevelHighlightingEnabled: false,
            interfaceMetrics: InterfaceMetrics(scale: 1),
            editorConfig: EditorConfigModel(fileService: FileService())
        )
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        editor.applyBaseTypography(to: textView)
        let base = try XCTUnwrap(textView.textColor, "the base typography left no foreground colour at all")
        try assertComponents(resolved(base, under: .darkAqua), equal: row.dark, "base foreground, dark")
        try assertComponents(resolved(base, under: .aqua), equal: row.light, "base foreground, light")

        // Site two: the no-grammar reset path, which writes the same row over the
        // whole storage when a file resolves to no language at all.
        let reset = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        reset.string = "plain text"
        let coordinator = CodeEditorView.Coordinator(text: binding)
        coordinator.updateHighlighter(for: reset, language: nil, contentReplaced: true)
        let storage = try XCTUnwrap(reset.textStorage)
        let written = try XCTUnwrap(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
            "the no-grammar reset path wrote no foreground colour"
        )
        try assertComponents(resolved(written, under: .darkAqua), equal: row.dark, "reset path, dark")
        try assertComponents(resolved(written, under: .aqua), equal: row.light, "reset path, light")
    }
}

#endif
