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
///   `Color.secondary` compile and look plausible in whichever appearance the
///   reviewer happens to be in. They do *not* desert the Theme preference — that
///   preference is applied as `.preferredColorScheme` at each window root, which
///   sets the window's `NSAppearance`, and a dynamic system colour resolves
///   against exactly that, the same signal a role does. What they desert is the
///   **palette**: they carry the platform's values rather than the table's, so a
///   view naming one draws a step off the roles beside it in *either* appearance
///   — which is the whole reason the roles exist.
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
/// - **No gated view derives a geometry value by arithmetic on a token.** A
///   padding written as half of another token reads as a measurement and is
///   really a coupling: nothing misrenders, and nothing names the relationship
///   either, so the day the other token moves this one moves with it.
/// - **The tab icon rule is spelled once.** The untitled-buffer fallback was
///   pasted into both orientations; two spellings of one rule drift, and each
///   copy also buys itself a line exempt from the first rule above.
/// - **The window's chrome is configured in one file.** A transparent title bar
///   is a property of the *window*, so two markers setting it would compete for
///   it silently — the ground decided by whichever reached the window first.
/// - **Every bottom-bar toggle is identifiable without sight.** The six panel
///   toggles and the completion switch are icon-only squares; the `Label` that
///   used to supply each one's accessibility name for free is gone, and an
///   unhidden `Image(systemName:)` supplies a name of its own instead — the
///   symbol's. A control that has quietly lost its title renders perfectly and
///   reads out as its glyph to VoiceOver — "square split bottom" where the
///   command's name belongs — which no other gate here can see. The bar's
///   widgets owe the same rule from the other side: they hide every symbol they
///   draw *and* spell an accessibility value, because two of those glyphs were
///   the row's state and hiding a state without speaking it is the same defect
///   with the counts looking healthy.
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
        // Part three: the window's own chrome.
        "MainWindowChrome.swift",
        "ContentView.swift",
        "ProjectSwitcherView.swift",
        "BranchSwitcherView.swift",
        "PullRequestIndicatorView.swift",
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
    /// resolves to the *platform's* value rather than the table's. They track the
    /// window's appearance, and therefore the Theme preference, as faithfully as a
    /// role does; the defect is the value, a step off the roles beside it in
    /// either appearance.
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
        try source(named: rulerFile)
    }

    /// The one file under `Sources/` with this name.
    private static func source(named name: String) throws -> URL {
        try XCTUnwrap(
            try swiftSources().first { $0.lastPathComponent == name },
            "\(name) is gone or renamed"
        )
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        code.components(separatedBy: needle).count - 1
    }

    /// The body of `drawHashMarksAndLabels(in:)`, brace-matched from its own
    /// declaration, so the rule above reads the drawing method alone and not the
    /// seam's own arithmetic beside it.
    private static func drawingBody(of code: String) -> String? {
        matchedBody(after: "func drawHashMarksAndLabels(", in: code)
    }

    /// The brace-matched body following the first occurrence of `declaration`.
    ///
    /// Rule six's helper, generalized when rule ten needed the same reading of a
    /// different declaration: one definition, so the two rules cannot come to
    /// disagree about what "this declaration's body" means.
    static func matchedBody(after declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration) else { return nil }
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

    // MARK: - Rule nine: the window's chrome is configured in one file

    /// The one file allowed to make a window's title bar transparent.
    ///
    /// `titlebarAppearsTransparent` is a property of the window, not of a view
    /// tree: whoever sets it last wins, and nothing in the compiler — or in any
    /// other gate here — can see two setters. A second one would not fail; it
    /// would simply decide the title bar's ground on some launches and not
    /// others, depending on which marker reached the window first. Pinned by set
    /// equality in both directions, so a *removed* setter is a failure too: the
    /// window's ground is the colour the transparency exists to reveal, and
    /// without it the framework's own material covers it.
    func testOnlyTheWindowChromeMakesATitleBarTransparent() throws {
        var setters: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if LSPSourceGatingTests.containsToken("titlebarAppearsTransparent", in: code) {
                setters.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            setters, ["MainWindowChrome.swift"],
            "the main window's chrome is configured in one file — a second setter competes with it"
        )
    }

    /// The scene's **one** attachment site.
    ///
    /// The setter's uniqueness above says nothing about whether anything ever
    /// reaches the window: `apply(to:)` is only ever called from the marker's
    /// `viewDidMoveToWindow()`, and the marker only ever runs because the scene
    /// attaches it. Delete `.background(MainWindowChrome())` and every other
    /// gate here stays green while the shipped window keeps its platform title
    /// bar — so the site is pinned by set equality, exactly as the frame
    /// marker's own suite pins its sibling on the same line.
    func testTheSceneAttachesTheWindowChromeExactlyOnce() throws {
        var attachers: [String] = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let sites = Self.occurrences(of: "MainWindowChrome(", in: code)
            if sites > 0 {
                attachers.append(contentsOf: Array(repeating: url.lastPathComponent, count: sites))
            }
        }
        XCTAssertEqual(
            attachers, ["PisakaApp.swift"],
            """
            the main window's chrome is attached once, by the scene — a missing attachment \
            leaves the window un-themed with every other rule here still green
            """
        )

        let scene = try Self.read(
            Self.document("Sources/Pisaka/PisakaApp.swift")
        )
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(scene)
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("MainWindowFrameAutosave", in: code),
            "the frame marker sits beside the chrome marker on the same line — neither may be lost"
        )
    }

    // MARK: - Rule ten: every bottom-bar control is identifiable without sight

    /// The window root, and the two toggle idioms whose bodies must each name a
    /// tooltip *and* an accessibility label.
    ///
    /// Part three made both icon-only. That is a visual decision with an
    /// invisible cost: a `Label(title, systemImage:)` is its own accessibility
    /// name, while an unhidden `Image(systemName:)` folds *its own symbol name*
    /// into whatever element it is combined into — so dropping the title does
    /// not leave the control nameless, it leaves it named after a glyph. Either
    /// way the name the title carried is gone, and `.help(` is a *tooltip*,
    /// which VoiceOver does not read as a name. Nothing misrenders, no test
    /// goes red, and the only reader who notices is the one who cannot see the
    /// bar at all.
    ///
    /// Read over the **brace-matched bodies** of the two declarations, in rule
    /// six's idiom, so a `.help(` somewhere else in this 1 400-line file cannot
    /// satisfy it. The call count is pinned too: one declaration plus six calls,
    /// so a seventh dock panel arriving without a glance at this rule fails here
    /// rather than shipping under its glyph's name.
    private static let windowRootFile = "ContentView.swift"

    /// The bar's three widgets, the same rule read from the other side.
    ///
    /// A `Button`'s children are combined into one element, so every
    /// `Image(systemName:)` a widget draws contributes its symbol name to the
    /// button's own — the announcement part one recorded on a tree row
    /// ("chevron.right, folder fill, Sources") is exactly that. A widget is
    /// therefore identifiable only if it either states its name outright with
    /// `.accessibilityLabel(`, or hides every decorative symbol it draws.
    ///
    /// Asserted by counting, in this suite's own `occurrences(of:in:)` idiom:
    /// each widget's `Image(systemName:` count must equal its
    /// `.accessibilityHidden(true)` count. A symbol added without a thought for
    /// the announcement moves one count and not the other.
    ///
    /// Counting alone was not enough, and the way it failed is the reason for
    /// the second half. A widget's symbol is usually decoration, but two of
    /// these are the row's **state** — `row.isCurrent ? "checkmark" : "folder"`
    /// and the branch list's checkmark — and hiding *those* satisfies the count
    /// while deleting the only thing that distinguished the current project, or
    /// the checked-out branch, from every other row. The count went green on a
    /// change that made the two lists unreadable without sight. So each of these
    /// files must also spell an accessibility **value**: the state carrier a
    /// hidden glyph owes back.
    ///
    /// What this rule does **not** see, said plainly because the honest limit is
    /// part of it: it cannot tell which symbol encoded state and does not try.
    /// A file could hide a state-bearing glyph and satisfy the value half with a
    /// value on some *other* row. What it pins is the shape of the regression it
    /// exists for — a file that hides every symbol it draws still says something
    /// about state — and the rest is the reviewer's, as the sweep's own rule
    /// says: a symbol whose name or colour varies with a value is state.
    private static let barWidgetFiles = [
        "ProjectSwitcherView.swift",
        "BranchSwitcherView.swift",
    ]

    /// The stated exception: the pull-request indicator names itself outright —
    /// an explicit `.accessibilityLabel(` plus an `.accessibilityValue(` — so
    /// what its two symbols would fold in never reaches the announcement.
    private static let labelledBarWidgetFile = "PullRequestIndicatorView.swift"

    func testEveryBottomBarToggleCarriesATooltipAndALabel() throws {
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: Self.windowRootFile))
        )
        for declaration in ["func bottomBarButton(", "var completionToggleButton"] {
            let body = try XCTUnwrap(
                Self.matchedBody(after: declaration, in: code),
                "\(declaration) is gone or renamed — re-point this rule rather than losing it"
            )
            for required in [".help(", ".accessibilityLabel("] {
                XCTAssertTrue(
                    body.contains(required),
                    """
                    \(Self.windowRootFile)'s \(declaration) must spell \(required) — an icon-only \
                    control is named after its glyph until an explicit label replaces that
                    """
                )
            }
        }
        // One declaration and six calls — the six bottom dock panels. A seventh
        // panel adds a call here, and this count is where it is asked whether
        // the new toggle is named.
        XCTAssertEqual(
            Self.occurrences(of: "bottomBarButton(", in: code), 7,
            """
            \(Self.windowRootFile) must spell bottomBarButton( exactly seven times — the declaration \
            and one call per bottom dock panel
            """
        )
    }

    func testEveryBottomBarWidgetHidesItsSymbolsAndSpeaksTheirState() throws {
        for name in Self.barWidgetFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            let symbols = Self.occurrences(of: "Image(systemName:", in: code)
            XCTAssertGreaterThan(
                symbols, 0,
                "\(name) draws no SF Symbol any more — re-point this rule rather than losing it"
            )
            XCTAssertEqual(
                Self.occurrences(of: ".accessibilityHidden(true)", in: code), symbols,
                """
                \(name) must hide every Image(systemName:) it draws — a button combines its \
                children, so an unhidden symbol folds its own name into the button's
                """
            )
            XCTAssertTrue(
                code.contains(".accessibilityValue("),
                """
                \(name) hides every symbol it draws and must therefore spell an \
                .accessibilityValue( — two of these glyphs are the row's state, not decoration, \
                and hiding a state without speaking it leaves the current row indistinguishable
                """
            )
        }

        let labelled = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: Self.labelledBarWidgetFile))
        )
        XCTAssertTrue(
            labelled.contains(".accessibilityLabel("),
            """
            \(Self.labelledBarWidgetFile) is the stated exception because it names itself \
            outright; without that label it owes the counting rule above
            """
        )
    }

    // MARK: - Rule eleven: every label the bar draws stays on one line

    /// The three widgets again, this time as the only files that draw a `Text`
    /// inside the bar's own fixed-height frame.
    ///
    /// Part three gave the bottom bar `frame(height:)` on
    /// `ChromeGeometry.bottomBarHeight`, where before its height came from the
    /// padding around its content. In a fixed-height frame a flexible `Text`
    /// does not make room for itself: a label long enough to wrap — a deep
    /// project folder, and especially a branch name, which is the one string
    /// here nobody chooses for its length — is laid out in two lines and drawn
    /// in one and a half, clipped by the frame instead of growing it. Nothing
    /// errors, nothing else goes red, and the bar looks right on every window
    /// wide enough.
    ///
    /// So each widget file must spell `.lineLimit(1)`, asserted in this suite's
    /// `contains` idiom over stripped source.
    ///
    /// The honest limit, stated with the rule as the two above state theirs: a
    /// source rule cannot see a layout. It sees the line that prevents this one
    /// — it cannot tell *which* `Text` in the file carries the limit, so a file
    /// whose bar label lost it while a popover row kept one would satisfy this.
    /// What it pins is that the construct is known here at all, which is what
    /// the widgets did not have: the limit was absent from all three.
    private static let barLabelFiles = [
        "ProjectSwitcherView.swift",
        "BranchSwitcherView.swift",
        "PullRequestIndicatorView.swift",
    ]

    func testEveryBottomBarLabelIsSingleLine() throws {
        for name in Self.barLabelFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            XCTAssertTrue(
                code.contains(".lineLimit(1)"),
                """
                \(name) draws a Text inside the bottom bar's fixed-height frame and must limit it \
                to one line — a label that wraps in a frame that cannot grow is a label drawn in \
                two lines and clipped to one and a half
                """
            )
        }
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

    // MARK: - The documented rule count

    /// The numbered rules above, counted from their own markers, and the two
    /// documents that summarise them.
    ///
    /// This is bookkeeping rather than a rule of its own: it gates no source file. It
    /// exists because the rules above are the kind of thing a reader learns
    /// about from a summary and not from the suite, and both summaries have
    /// already drifted once — `core-theme.md`'s canonical list named five of
    /// eight and `CLAUDE.md` six, each correct on the day it was written. A
    /// count that drifts is worse than no count: it tells a reader the sweep is
    /// smaller than it is, and the rules it omits are the newest ones.
    ///
    /// Shaped after `LintConfigurationTests`' style-version pair: one source of
    /// truth — here the markers themselves — and every document spelling it
    /// checked against that, in the sentence that names it rather than anywhere
    /// in the file.
    static func declaredRuleCount() throws -> Int {
        let source = try read(URL(fileURLWithPath: #filePath))
        let markers = try NSRegularExpression(pattern: "(?m)^\\s*// MARK: - Rule [a-z]+:")
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let count = markers.numberOfMatches(in: source, range: range)
        XCTAssertGreaterThan(count, 0, "the rule markers are gone or reworded — re-point this count")
        return count
    }

    /// English for the numbers a rule count can plausibly be; a suite growing
    /// past this has outgrown a prose summary too.
    private static let spelled = [
        1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six",
        7: "seven", 8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve",
    ]

    func testBothSummariesSpellTheSuitesOwnRuleCount() throws {
        let count = try Self.declaredRuleCount()
        let word = try XCTUnwrap(Self.spelled[count], "no spelling for \(count) rules")

        let theme = try Self.read(Self.document("docs/architecture/core-theme.md"))
        XCTAssertTrue(
            theme.contains("The \(word) rules, each invisible to the compiler:"),
            """
            core-theme.md's canonical list must open on the suite's own count (\(count)); a reader \
            consults that list to learn what the suite enforces
            """
        )

        let index = try Self.read(Self.document("CLAUDE.md"))
        XCTAssertTrue(
            index.contains("and its \(word) rules"),
            "CLAUDE.md's chrome-theme invariant must name the suite's own rule count (\(count))"
        )
    }

    /// The canonical list must also *have* that many items: a corrected count
    /// over an uncorrected enumeration is the same defect wearing the right
    /// number.
    func testTheCanonicalListEnumeratesEveryRule() throws {
        let count = try Self.declaredRuleCount()
        let word = try XCTUnwrap(Self.spelled[count], "no spelling for \(count) rules")
        let theme = try Self.read(Self.document("docs/architecture/core-theme.md"))
        let opening = try XCTUnwrap(
            theme.range(of: "The \(word) rules, each invisible to the compiler:"),
            "the canonical list's opening sentence is gone — re-point this rule rather than losing it"
        )
        let rest = theme[opening.upperBound...]
        let end = rest.range(of: "\nPlus a ")?.lowerBound ?? rest.endIndex
        let list = String(rest[..<end])
        let items = try NSRegularExpression(pattern: "(?m)^([0-9]+)\\. \\*\\*")
        let range = NSRange(list.startIndex..<list.endIndex, in: list)
        let numbers = items.matches(in: list, range: range).compactMap { match -> Int? in
            guard let digits = Range(match.range(at: 1), in: list) else { return nil }
            return Int(list[digits])
        }
        XCTAssertEqual(
            numbers, Array(1...count),
            "the canonical list must enumerate all \(count) rules, in order, one bolded item each"
        )
    }

    private static func document(_ relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(relativePath) is gone or moved")
        return url
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
