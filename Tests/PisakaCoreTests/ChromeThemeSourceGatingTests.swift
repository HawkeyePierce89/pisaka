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
/// - **The gutter's fill still goes through its own rule.** A pure seam is only
///   worth what its call site spends: the regression this branch exists to fix
///   was one line in a drawing method, and every other gate stayed green while
///   it painted the editor out.
/// - **The tab icon rule is spelled once.** The untitled-buffer fallback was
///   pasted into both orientations; two spellings of one rule drift, and each
///   copy also buys itself a line exempt from the first rule above.
/// - **No gated view derives a geometry value by arithmetic on a token.** A
///   padding written as half of another token reads as a measurement and is
///   really a coupling: nothing misrenders, and nothing names the relationship
///   either, so the day the other token moves this one moves with it.
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
        "BreadcrumbBarView.swift",
        "MinimapView.swift",
        "LSPConsentBanner.swift",
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
            .filter { !constructsFileIcon($0) }
    }

    /// Whether this line constructs a `FileIcon` — the boundary-aware form, so
    /// `TabFileIcon(`, a view *named* after the icon it draws, buys no exemption
    /// from rule one. One definition, read by the exemption above and by the
    /// rule that counts what it exempts, so the two cannot drift apart.
    static func constructsFileIcon(_ line: String) -> Bool {
        guard let pattern = try? NSRegularExpression(
            pattern: "(^|[^A-Za-z0-9_])FileIcon\\("
        ) else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return pattern.firstMatch(in: line, range: range) != nil
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

    // MARK: - Rule six: the gutter's fill goes through its own rule

    /// The ruler file, and the two spellings of the rule its background fill
    /// must go through.
    ///
    /// `LineNumberRulerBackgroundTests` pins what
    /// `backgroundRect(in:ruleThickness:)` *answers*; nothing there can see
    /// whether `drawHashMarksAndLabels` still asks it. That gap is not
    /// hypothetical: restoring the one line this rule guards — `rect.fill()`,
    /// filling the rectangle an `NSRulerView` was handed rather than the gutter's
    /// own — is the exact regression this branch exists to fix, it paints the
    /// code and the minimap out in `bgEditor`, and it leaves the seam's own
    /// tests, `swift test`, the app bundle and SwiftLint all green. The seam
    /// carries a long doc comment naming the regression; the call site is one
    /// unremarkable line in a sixty-line drawing method, which makes it the
    /// likelier of the two to be edited and the only one nothing was watching.
    ///
    /// Shaped after `FoldingSourceGatingTests`' reveal-funnel rule: one
    /// definition, a counted set of callers, plus the forbidden bare form.
    private static let rulerFile = "LineNumberRulerView.swift"

    func testTheGutterFillGoesThroughItsOwnRule() throws {
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.rulerSource())
        )
        // Twice, exactly: the `static func` declaration and its one call. A third
        // is a second answer to the same question; a first-and-only is a seam
        // nobody calls.
        XCTAssertEqual(
            Self.occurrences(of: "backgroundRect(", in: code), 2,
            """
            \(Self.rulerFile) must spell backgroundRect( exactly twice — the rule and the one call \
            site that spends it
            """
        )
        // And the bare form the regression wore. `visibleRect.fill(` and friends
        // are not matched: the boundary is an identifier character, so only the
        // handed-in `rect` itself trips this.
        let bare = try NSRegularExpression(pattern: "(^|[^A-Za-z0-9_.])rect\\.fill\\(")
        let body = try XCTUnwrap(
            Self.drawingBody(of: code),
            "drawHashMarksAndLabels is gone or renamed — re-point this rule rather than losing it"
        )
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        XCTAssertNil(
            bare.firstMatch(in: body, range: range),
            """
            the ruler is handed the rectangle it was asked to redraw, which regularly spans the whole \
            editor pane — filling it wholesale paints the code out
            """
        )
    }

    private static func rulerSource() throws -> URL {
        try XCTUnwrap(
            try swiftSources().first { $0.lastPathComponent == rulerFile },
            "\(rulerFile) is gone or renamed"
        )
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    /// The body of `drawHashMarksAndLabels(in:)`, brace-matched from its own
    /// declaration, so the rule above reads the drawing method alone and not the
    /// seam's own arithmetic beside it.
    private static func drawingBody(of code: String) -> String? {
        guard let start = code.range(of: "func drawHashMarksAndLabels(") else { return nil }
        guard let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[code.index(after: open)..<index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    // MARK: - Rule seven: no geometry token is derived by arithmetic

    /// `ChromeGeometry`'s first rule says it in words: every token is scaled at
    /// its use site, and **no view multiplies one of these numbers by anything
    /// itself**. This is the rule as something a suite can see.
    ///
    /// What it forbids is a chrome surface *deriving a design value locally* —
    /// a token combined with a number, as in a vertical padding written as half
    /// a horizontal row-padding token. Nothing misrenders when it happens: the
    /// tokens are `Double`s, so the arithmetic is exact and the scale is still
    /// applied once. The cost is the coupling, which nothing names: a later
    /// change to a horizontal row-padding token would move an unrelated vertical
    /// padding with it, and the reader of either line has no way to know. A
    /// surface's own measurement is a bare local number — which the sweep guide
    /// permits, and which the same call sites already use for their other
    /// spacings.
    ///
    /// **What it deliberately does not match:** a token combined with a *layout*
    /// value rather than a number, such as the ruler placing its trailing rule
    /// at `ruleThickness - hairlineWidth`. That composes a position out of a
    /// width the drawing code was handed; it invents no second design value, and
    /// widening this rule to cover it would forbid the only honest way to draw
    /// an edge.
    func testNoGatedFileDerivesAGeometryTokenByArithmetic() throws {
        // A token on either side of an arithmetic operator from a number: both
        // directions, and `CGFloat(…)` around the token does not hide it.
        let derivations = [
            try NSRegularExpression(pattern: "ChromeGeometry\\.[A-Za-z0-9_]+\\s*\\)?\\s*[*/+-]\\s*[0-9.]"),
            try NSRegularExpression(pattern: "[0-9.]\\s*[*/+-]\\s*(CGFloat\\()?\\s*ChromeGeometry\\."),
        ]
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            for pattern in derivations {
                XCTAssertNil(
                    pattern.firstMatch(in: code, range: range),
                    """
                    \(url.lastPathComponent) derives a geometry value from a ChromeGeometry token by \
                    arithmetic — a surface's own measurement is a bare local number, scaled once at \
                    the use site
                    """
                )
            }
        }
    }

    // MARK: - Rule eight: the tab icon rule is spelled once

    /// The untitled-buffer icon fallback — an `OpenFile` with no url asked about
    /// under its `displayName`, so the symbol is `FileIcon`'s own fallback
    /// rather than a second guess — is one rule, and `TabFileIcon` is its one
    /// spelling.
    ///
    /// It was pasted into both orientations once already, which is the failure
    /// `TabStatusMark` exists to refuse: two spellings of one rule drift the
    /// moment either is touched, and nothing in the compiler can see that they
    /// have. The paste had a second cost this suite can see from the other side
    /// — `iconFreeLines` drops every line naming `FileIcon(` from rule one's
    /// scan, so each copy bought itself a line exempt from the no-system-colour
    /// check. Both halves are pinned here by set equality: one declaration, and
    /// a counted set of gated files carrying an exempted line.
    func testTheTabIconRuleIsSpelledOnce() throws {
        var declarers: Set<String> = []
        var fallbackSpellers: Set<String> = []
        var iconNamers: Set<String> = []
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains("struct TabFileIcon") { declarers.insert(name) }
            if code.contains("file.url ?? URL(fileURLWithPath: file.displayName)") {
                fallbackSpellers.insert(name)
            }
            let constructsIcon = code
                .components(separatedBy: .newlines)
                .contains(where: Self.constructsFileIcon)
            if Self.gatedFiles.contains(name) && constructsIcon {
                iconNamers.insert(name)
            }
        }
        XCTAssertEqual(
            declarers, ["TabStripView.swift"],
            "the shared tab icon is one view, declared beside TabStatusMark and for its reason"
        )
        XCTAssertEqual(
            fallbackSpellers, ["TabStripView.swift"],
            """
            the untitled-buffer icon fallback is one rule — a second spelling of it is the drift \
            TabFileIcon exists to refuse
            """
        )
        // Three, and named: the tree's rows, the inline draft field drawing the
        // placeholder icon a real row would have, and the shared tab icon both
        // orientations now ask. A fourth is a line that has quietly bought
        // itself out of rule one.
        XCTAssertEqual(
            iconNamers,
            ["ProjectTreeDraftField.swift", "ProjectTreeView.swift", "TabStripView.swift"],
            "a gated file naming FileIcon( carries a line exempt from rule one — keep the set small"
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
