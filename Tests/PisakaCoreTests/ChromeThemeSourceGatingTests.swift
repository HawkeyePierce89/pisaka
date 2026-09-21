import XCTest
@testable import PisakaCore

/// Static verification of the chrome theme's cross-cutting rules — the ones
/// `swift test` cannot otherwise see, because every one of them lives in the
/// (untested by convention) macOS view layer.
///
/// A repository-file suite in the `ZoomSourceGatingTests` mould: it reads
/// `Sources/` through `#filePath` with Foundation only, and it matches against
/// `LSPSourceGatingTests.strippingCommentsAndStringLiterals(_:)` output, so
/// **comments and string literals are stripped before anything is matched**.
/// That is load-bearing rather than tidy here: the gated files document their own
/// rules at length — `ChromePalette.swift` explains what a hex literal outside it
/// would cost, `TabStripView.swift` names the accent colour it no longer uses in
/// order to say it does not, and `LineNumberRulerView.swift` spells
/// `ChromeColorRole.textSecondary` in prose — so a raw `contains` would pass on
/// all three while the code they name was deleted.
///
/// What is checked, and why each rule is invisible to the compiler:
///
/// - **No gated view names a system semantic colour.** `NSColor.labelColor` and
///   `Color.secondary` compile, look plausible in whichever appearance the
///   reviewer happens to be in, and quietly desert the palette the moment the
///   Theme preference disagrees with the system one — which is the whole reason
///   the roles exist.
/// - **No gated view spells a hex literal.** A colour written where it is drawn
///   is a colour nothing can re-theme; the table is the one place a value may
///   live, and `ChromePalette.swift` is checked by its own app-layer suite
///   instead.
/// - **The three exemptions stay exemptions.** A token-kind colour table, an
///   ANSI-16 palette and a Core icon token are three things that are *not*
///   chrome; the sweep that follows must not quietly fold them in.
/// - **The theme is injected wherever the interface scale is.** A root that
///   gains one modifier and forgets the other draws its whole window in the
///   resting appearance: no error, no warning, and it looks right until the
///   preference is changed.
/// - **No view constructs a theme inline.** A view building its own
///   `ChromeTheme` reads the preference it was handed and then stops hearing
///   about it.
final class ChromeThemeSourceGatingTests: XCTestCase {

    // MARK: - The gated set

    /// The view files restyled onto the roles, and therefore held to the two
    /// rules below.
    ///
    /// Asserted by **set equality** in both directions: a file named here that no
    /// longer exists fails, so the follow-up sweep adds a file to this set
    /// deliberately, as part of restyling it, rather than discovering later that
    /// it was never covered.
    ///
    /// `ProjectTreeDraftField.swift` is in the set although it is an editing
    /// affordance rather than a row: an inline draft *replaces* a tree row on
    /// screen and must read identically to the row it stands in for.
    static let gatedFiles: Set<String> = [
        "ChromePalette.swift",
        "ChromeThemeEnvironment.swift",
        "TabStripView.swift",
        "LineNumberRulerView.swift",
        "ProjectTreeView.swift",
        "ProjectTreeDraftField.swift",
        // Part two: the editor pane's own chrome.
        "TabListView.swift",
        "TabRowView.swift",
    ]

    func testEveryGatedFileExists() throws {
        let present = Set(
            try Self.swiftSources()
                .map(\.lastPathComponent)
                .filter { Self.gatedFiles.contains($0) }
        )
        XCTAssertEqual(
            present, Self.gatedFiles,
            "a gated file is gone or renamed — update gatedFiles rather than losing the coverage"
        )
    }

    // MARK: - Rule one: no system semantic colour

    /// The semantic colours **no** gated file may name, the table included.
    ///
    /// AppKit's semantic set plus SwiftUI's four hierarchical ones: a closed list
    /// rather than a pattern, because the point is to name the specific things a
    /// view reaches for when it wants "the usual text colour", each of which
    /// resolves against the *system* appearance and so ignores the Theme
    /// preference entirely.
    ///
    /// `clear` is deliberately absent and allowed: it is the absence of a colour,
    /// not a role, and a row that paints nothing when it is in no state is
    /// saying exactly that.
    static let forbiddenSemanticColors: [String] = [
        // AppKit
        "labelColor",
        "secondaryLabelColor",
        "tertiaryLabelColor",
        "textBackgroundColor",
        "controlBackgroundColor",
        "windowBackgroundColor",
        "separatorColor",
        "selectedContentBackgroundColor",
        "systemRed",
        "systemGreen",
        "systemYellow",
        "systemBlue",
        "systemGray",
        // SwiftUI
        "accentColor",
        "primary",
        "secondary",
        "tertiary",
    ]

    /// SwiftUI's named hues, forbidden to the gated **views** only.
    ///
    /// The table is exempt from this half and from this half alone, for the same
    /// reason it is exempt from the hex rule: `red`/`green`/`blue` are the
    /// argument labels of `Color(.sRGB, red:green:blue:opacity:)`, so a palette
    /// composing a value out of its channels spells three of these words while
    /// naming no colour at all. Every semantic token above still applies to it.
    static let forbiddenHues: [String] = [
        "red",
        "green",
        "blue",
        "yellow",
        "orange",
        "purple",
        "pink",
        "brown",
        "indigo",
        "mint",
        "teal",
        "cyan",
        "gray",
    ]

    func testNoGatedFileNamesASystemSemanticColor() throws {
        var offenders: [String] = []
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let forbidden = name == "ChromePalette.swift"
                ? Self.forbiddenSemanticColors
                : Self.forbiddenSemanticColors + Self.forbiddenHues
            for line in Self.iconFreeLines(of: code) {
                for token in forbidden where LSPSourceGatingTests.containsToken(token, in: line) {
                    offenders.append("\(name): \(token)")
                }
            }
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            "a gated view must ask the palette for a role, never the system for a colour"
        )
    }

    /// The stripped source's lines, minus the ones that construct a `FileIcon`.
    ///
    /// The hue names above collide with `FileIconColor`'s cases, and a
    /// `FileIconColor` is the third exemption read from the other side: a Core
    /// semantic token that names a meaning, not a system colour. The one gated
    /// site that spells one — the draft field's placeholder icon — does so as an
    /// argument to `FileIcon(`, on that line and nowhere else, so dropping those
    /// lines costs the rule nothing it was meant to catch.
    private static func iconFreeLines(of code: String) -> [String] {
        code
            .components(separatedBy: .newlines)
            .filter { !$0.contains("FileIcon(") }
    }

    // MARK: - Rule two: no hex literal outside the table

    func testOnlyThePaletteSpellsAHexColorLiteral() throws {
        let hex = try NSRegularExpression(pattern: "0x[0-9A-Fa-f]{6}")
        var spellers: Set<String> = []
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            if hex.firstMatch(in: code, range: range) != nil {
                spellers.insert(url.lastPathComponent)
            }
        }
        // Set equality in both directions: a second speller is a colour nothing
        // can re-theme, and a palette that has stopped spelling any is a table
        // that has stopped being one — its own app-layer suite checks the values,
        // but only this one can see that the exemption is still earned.
        XCTAssertEqual(
            spellers, ["ChromePalette.swift"],
            "the hex table is the one place a colour value may live"
        )
    }

    // MARK: - Rule three: the three exemptions stay out of the gated set

    /// Files that spell colours and are deliberately **not** chrome.
    ///
    /// - `SyntaxTheme.swift` — a token-kind colour table belongs to the code
    ///   zone, which is the editor's own theme, not the chrome's design system.
    /// - `TerminalTheme.swift` — an ANSI-16 palette is a protocol's vocabulary:
    ///   the numbers mean what the escape sequences say they mean, and a role
    ///   cannot stand in for one.
    /// - `FileIcon.swift` — a Core semantic token that iOS still paints, so it
    ///   cannot move behind a macOS-only palette.
    static let colorExemptions: Set<String> = [
        "SyntaxTheme.swift",
        "TerminalTheme.swift",
        "FileIcon.swift",
    ]

    func testTheExemptionsAreNotGated() throws {
        XCTAssertTrue(
            Self.colorExemptions.isDisjoint(with: Self.gatedFiles),
            "an exemption cannot also be gated — decide which it is, in the doc comment above"
        )
        // They must still be there: an exemption naming a file that is gone is a
        // reason nobody will re-read.
        let present = Set(try Self.swiftSources().map(\.lastPathComponent))
        XCTAssertTrue(
            Self.colorExemptions.isSubset(of: present),
            "an exempted file is gone — update colorExemptions with the reason it no longer applies"
        )
    }

    // MARK: - Rule four: injected at the interface scale's own roots

    func testTheThemeIsInjectedAtTheInterfaceScaleRoots() throws {
        var found: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains(".chromeThemed(") { found.insert(url.lastPathComponent) }
        }
        // Read from `ZoomSourceGatingTests`' own declaration rather than copied:
        // the two modifiers answer the same question ("is this a SwiftUI root?"),
        // so a root that gains one and forgets the other must fail in exactly one
        // place, not pass two lists that have drifted apart.
        XCTAssertEqual(
            found, ZoomSourceGatingTests.interfaceScaledRoots,
            "the chrome theme is injected wherever the interface scale is — the roots are one list"
        )
    }

    // MARK: - Rule five: no view constructs a theme

    func testOnlyThePlumbingConstructsATheme() throws {
        var constructors: Set<String> = []
        var namers: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains("ChromeTheme(") { constructors.insert(url.lastPathComponent) }
            if LSPSourceGatingTests.containsToken("ChromeTheme", in: code) {
                namers.insert(url.lastPathComponent)
            }
        }
        // Two files, two roles: the type is declared beside the table it reads,
        // and built only by the plumbing that resolves the preference. A view
        // reads it out of the environment and never names it at all — which is
        // also why the naming set is checked separately from the constructing
        // one, the wider of the two being the one a view would first join.
        XCTAssertEqual(
            namers, ["ChromePalette.swift", "ChromeThemeEnvironment.swift"],
            "a view reads the theme from the environment; it does not name the type"
        )
        XCTAssertEqual(
            constructors, ["ChromeThemeEnvironment.swift"],
            "a view building its own theme stops hearing about the preference it was built from"
        )
    }

    // MARK: - Self-check

    /// Every gated file draws with roles and must therefore name one — with a
    /// single exception: `ChromeThemeEnvironment.swift` carries the *appearance*
    /// down the tree and paints nothing, so it names no role by construction. It
    /// stays gated for the two rules above, which is what it can break.
    private static let roleNamingExemption = "ChromeThemeEnvironment.swift"

    func testEveryGatedFileActuallyNamesARole() throws {
        for url in try Self.swiftSources()
        where Self.gatedFiles.contains(url.lastPathComponent)
            && url.lastPathComponent != Self.roleNamingExemption {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let namesRole = ChromeColorRole.allCases.contains {
                LSPSourceGatingTests.containsToken($0.rawValue, in: code)
            }
            XCTAssertTrue(
                namesRole,
                """
                \(url.lastPathComponent) names no colour role — either it was restyled away from the \
                palette, or the roles were renamed and the checks above have gone vacuous
                """
            )
        }
    }

    // MARK: - Reading the sources

    /// Every Swift file under `Sources/`, found relative to this file so the
    /// suite needs no bundle and no Xcode build.
    private static func swiftSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PisakaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "Sources/ is unreadable"
        )
        let urls = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty, "found no Swift sources — the walk is broken, not the code")
        return urls
    }

    private static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
