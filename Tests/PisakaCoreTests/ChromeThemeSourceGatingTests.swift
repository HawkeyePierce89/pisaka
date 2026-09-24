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
/// - **The four exemptions stay exemptions.** A token-kind colour table, an
///   ANSI-16 palette, a Core icon token and the branch graph's lane palette are
///   four things that are *not* chrome; the sweep that follows must not quietly
///   fold them in.
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
/// - **Every label the bar draws stays on one line.** The bar states its own
///   height, so a label that wraps is clipped rather than accommodated — and it
///   wraps only at the width, scale or project name the reviewer did not try.
/// - **The dock's tab row is configured in one place.** It is drawn once, from
///   the slot every panel passes through; a second call site compiles and
///   stacks a second row.
/// - **Every dock tab and the close action are identifiable without sight.** A
///   tab's selection is a shape, so it is spoken as a value; the close action is
///   an icon-only glyph, so it is named outright.
/// - **The dock's swept surfaces draw their own rules.** A `Divider()` is the
///   platform's separator colour, a step off the `hairline` role beside it, and
///   it compiles and looks plausible in whichever appearance the reviewer is in.
/// - **The severity mapping is Core's one answer.** A second severity table in a
///   view compiles, draws four plausible colours, and drifts from the gutter's
///   the first time either is touched.
/// - **An indicator strip's bottom rule is drawn behind its tabs.** An overlaid
///   rule paints over the lower point of the active tab's accent indicator — a
///   one-point overlap no compiler or headless test can see.
/// - **The changed-file status mapping is Core's one answer.** The letter and
///   role a status is drawn in were written out twice before; a view growing a
///   third `switch` compiles and disagrees with the panel beside it the first
///   time either is touched.
/// - **The checks-state mapping is Core's one answer.** The panel and the
///   bottom-bar indicator draw the same state; a second table in either drifts
///   from the other without a sound.
/// - **The diff wash is Core's one answer, and a diff side is one type.** The
///   two diff surfaces wash their rows from `diffWashRole`, over Core's one
///   `DiffSide` — a second side enum in the app is the seam the old one was.
/// - **The three panels' controls are identifiable without sight.** The Log,
///   Local Changes and Pull Requests panels' icon-only controls are named, their
///   state carriers speak a value, and every symbol inside a labelled control is
///   hidden by a modifier of its own — not a later sibling's.
/// - **The Log's filter bar states no fixed width and scrolls below its floor.**
///   A fixed width clipped the row, and the branch menu and message search with
///   it, below roughly 1000 points; it renders perfectly at a reviewer's width.
/// - **A pushed resize cursor is released when its view disappears.** A divider
///   leaving the tree gets neither `onHover(false)` nor `onEnded`, and
///   `NSCursor`'s stack is global, so the cursor stays pushed after the flag
///   that would have balanced it is gone.
/// - **A popover surface names `bgPopover`.** The five gated popover surfaces
///   name `bgPopover` and no other gated file does; every gated file presenting
///   a popover (`.popover(`) or declaring an `NSPanel` is in that set; no gated
///   file spells `NSVisualEffectView`, a `.material` assignment or
///   `presentationBackground`.
/// - **`Divider()` in exactly one place.** The one separator a gated file may
///   spell is the menu's, in `SearchHistoryMenu.swift`, with exactly one
///   occurrence there.
/// - **AppKit layer colours are set only inside the drawing appearance.** Every
///   `borderColor` and `backgroundColor` assignment in the two popover panels
///   lies inside a `performAsCurrentDrawingAppearance` body, naming `hairline` and
///   `bgPopover` respectively.
/// - **One field shape.** No gated file spells the rounded-border style; the
///   shared field/box is constructed in exactly four callers plus the defining
///   file.
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
        // Part four (a): the dock's own chrome.
        "DockTabRow.swift",
        "ProblemsPanelView.swift",
        "UsagesPanelView.swift",
        "TerminalPanelView.swift",
        // Part four (b): the dock's remaining panels, the diff pane and the
        // unified diff's wash. `CommitGraphView.swift` is gated although it
        // spells no colour at all: it asks `CommitGraphPalette` (the fourth
        // exemption) for every lane, so what being here enforces is the two
        // negative rules — no system colour, no hex literal — and that the
        // lane table never moves back into the view.
        "CommitLogView.swift",
        "CommitGraphView.swift",
        "LogFilterBar.swift",
        "LocalChangesView.swift",
        "DiffView.swift",
        "CommitUnifiedDiffView.swift",
        "PullRequestsPanelView.swift",
        "ChromeControls.swift",
        "CompletionPanel.swift",
        "HoverPanel.swift",
        "SearchBarView.swift",
        "SearchHistoryMenu.swift",
        "ProjectSearchView.swift",
        "ProjectSearchWindowController.swift",
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

    // MARK: - Rule three: the four exemptions stay out of the gated set

    /// Files that spell colours and are deliberately **not** chrome.
    ///
    /// - `SyntaxTheme.swift` — a token-kind colour table belongs to the code
    ///   zone, which is the editor's own theme, not the chrome's design system.
    /// - `TerminalTheme.swift` — an ANSI-16 palette is a protocol's vocabulary:
    ///   the numbers mean what the escape sequences say they mean, and a role
    ///   cannot stand in for one.
    /// - `FileIcon.swift` — a Core semantic token that iOS still paints, so it
    ///   cannot move behind a macOS-only palette.
    /// - `CommitGraphPalette.swift` — a lane colour is an identity token, not a
    ///   chrome meaning: it says "this line is the same branch as that one", and
    ///   no role names that. The eight hues are today's system values carried
    ///   over as light/dark pairs; `CommitGraphPaletteTests` pins them.
    static let colorExemptions: Set<String> = [
        "SyntaxTheme.swift",
        "TerminalTheme.swift",
        "FileIcon.swift",
        "CommitGraphPalette.swift",
    ]

    func testTheExemptionsAreNotGated() throws {
        XCTAssertTrue(
            Self.colorExemptions.isDisjoint(with: Self.gatedFiles),
            "one of the four exemptions is also gated — decide which it is, in the doc comment above"
        )
        // They must still be there: an exemption naming a file that is gone is a
        // reason nobody will re-read.
        let present = Set(try Self.swiftSources().map(\.lastPathComponent))
        XCTAssertTrue(
            Self.colorExemptions.isSubset(of: present),
            "one of the four exempted files is gone — update colorExemptions with the reason it no longer applies"
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
        // Seven, and named: the tree's rows, the inline draft field drawing the
        // placeholder icon a real row would have, the shared tab icon both
        // orientations now ask, and — since part four (a) — the Problems and
        // Usages panels' file-group headers, each of whose exempted line is a
        // `let icon = FileIcon(…)` binding read for its symbol alone (the glyph
        // is drawn in `textSecondary`, a role, on a line rule one still scans).
        // Part four (b) adds the Log's changed-file row and Local Changes' rows
        // and folder headers, whose exempted lines are the same binding.
        // An eighth is a line that has quietly bought itself out of rule one.
        XCTAssertEqual(
            iconNamers,
            [
                "ProjectTreeDraftField.swift", "ProjectTreeView.swift", "TabStripView.swift",
                "ProblemsPanelView.swift", "UsagesPanelView.swift",
                "CommitLogView.swift", "LocalChangesView.swift",
            ],
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
    /// satisfy it. The call count is pinned too: one declaration plus one call,
    /// inside `panelToggles` — the bar builds its toggles from
    /// `BottomPanel.allCases` and **names no panel case in that body**, so it
    /// keeps no second list of panels beside the one the dock's tab row reads.
    /// `BottomPanelTests` pins the order; this rule pins who reads it. A seventh
    /// panel therefore arrives through the same builder whose name this rule
    /// already requires.
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
        // One declaration and one call — the call inside `panelToggles`, over
        // `allCases`. A hand-written seventh call is a second list of panels.
        XCTAssertEqual(
            Self.occurrences(of: "bottomBarButton(", in: code), 2,
            """
            \(Self.windowRootFile) must spell bottomBarButton( exactly twice — the declaration \
            and the one call inside panelToggles, over BottomPanel.allCases
            """
        )
        let bar = try XCTUnwrap(
            Self.matchedBody(after: "var bottomBar:", in: code),
            "bottomBar is gone or renamed — re-point this rule rather than losing it"
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("panelToggles", in: bar),
            "bottomBar must draw its panel toggles through panelToggles"
        )
        let toggles = try XCTUnwrap(
            Self.matchedBody(after: "var panelToggles:", in: code),
            "panelToggles is gone or renamed — re-point this rule rather than losing it"
        )
        XCTAssertTrue(
            toggles.contains("BottomPanel.allCases"),
            "panelToggles must build the bar's toggles from BottomPanel.allCases — the dock's tab row's one list"
        )
        XCTAssertTrue(toggles.contains("bottomBarButton("), "panelToggles must call bottomBarButton(")
        for panelCase in [".terminal", ".log", ".changes", ".problems", ".usages", ".pullRequests"] {
            XCTAssertFalse(
                toggles.contains(panelCase),
                """
                panelToggles names \(panelCase) — a panel spelled here is a second list beside \
                BottomPanel.allCases, and reordering the enum would reorder the tab row alone
                """
            )
        }
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

    /// The files that draw a `Text` inside a fixed-height chrome strip: the
    /// bar's three widgets, and since part four (a) the dock's tab row and the
    /// Problems, Usages and Terminal panels, whose headers are
    /// `panelHeaderHeight` strips.
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
    /// The dock's tab row is the same shape one strip up: its labels sit in
    /// `ChromeGeometry.dockTabRowHeight`, a frame that cannot grow either.
    ///
    /// The rule takes one of two forms per file, over stripped source.
    ///
    /// **Whole file** — `barLabelFiles` must each spell `.lineLimit(1)`
    /// somewhere, in this suite's `contains` idiom. That is the honest check
    /// where the strip *is* the file's view: the bar's three widgets, whose one
    /// bar label the limit was absent from altogether, and the dock's tab row,
    /// whose only `Text` is its tab label.
    ///
    /// **Header builder** — `headerBuilderFiles` name, per panel, the builders
    /// that draw the panel's fixed-height header strip, and inside each one's
    /// brace-matched body (rule ten's reading of the bar's button builder) the
    /// count of `.lineLimit(1)` must equal the count of `Text(`: every label the
    /// strip draws carries its own limit. A file-level `contains` cannot pin
    /// these, and that is how it failed: each of the three panels already spelled
    /// `.lineLimit(1)` on master — a file-group path, the identifier, a session
    /// title — so the check was satisfied by an older occurrence and deleting the
    /// limit from the new "Problems" title, the badge count, the provenance note
    /// or the count label left the suite green. A builder renamed or removed
    /// fails loudly rather than silently narrowing the rule to nothing.
    ///
    /// The honest limit, stated with the rule as the two above state theirs: a
    /// source rule cannot see a layout. The whole-file form cannot tell *which*
    /// `Text` in the file carries the limit, so a widget whose bar label lost it
    /// while a popover row kept one would satisfy it — any older occurrence
    /// satisfies a file-level `contains`. The builder form counts spellings, so
    /// a `Text` built outside the named builders (or a limit spelled on a
    /// container rather than on each label) is not what it sees; what it pins
    /// is that each label the header draws is written with its limit beside it.
    private static let barLabelFiles = [
        "ProjectSwitcherView.swift",
        "BranchSwitcherView.swift",
        "PullRequestIndicatorView.swift",
        "DockTabRow.swift",
    ]

    /// Each panel's header-strip builders, by declaration: the Problems header
    /// and the severity badge it draws, the Usages header, and the Terminal
    /// strip's per-session tab.
    ///
    /// Part four (b) adds the Log's header strip and its static column-header
    /// row's `label(_:)`, the filter bar's two label builders (the field and the
    /// date bound — the branch picker's menu items are menu rows, not strip
    /// labels, so `refPicker` is not named), the Local Changes toolbar, and the
    /// Pull Requests header and row line.
    private static let headerBuilderFiles: [(file: String, builders: [String])] = [
        ("ProblemsPanelView.swift", ["private var header: some View", "private func severityBadge("]),
        ("UsagesPanelView.swift", ["private var header: some View"]),
        ("TerminalPanelView.swift", ["private func tab(for session:"]),
        ("CommitLogView.swift", ["private var header: some View", "private func label(_ text: String)"]),
        ("LogFilterBar.swift", ["private func dateBound("]),
        ("LocalChangesView.swift", ["private var toolbar: some View"]),
        ("PullRequestsPanelView.swift", ["private var header: some View", "private var summaryLine: some View"]),
    ]

    func testEveryBottomBarLabelIsSingleLine() throws {
        for name in Self.barLabelFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            XCTAssertTrue(
                code.contains(".lineLimit(1)"),
                """
                \(name) draws a Text inside a fixed-height chrome strip and must limit it \
                to one line — a label that wraps in a frame that cannot grow is a label drawn in \
                two lines and clipped to one and a half
                """
            )
        }
        for (name, builders) in Self.headerBuilderFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            for builder in builders {
                let body = try XCTUnwrap(
                    Self.matchedBody(after: builder, in: code),
                    "\(name)'s \(builder) is gone or renamed — re-point this rule rather than losing it"
                )
                let labels = Self.occurrences(of: "Text(", in: body)
                XCTAssertGreaterThan(
                    labels, 0,
                    "\(name)'s \(builder) draws no Text any more — re-point this rule rather than losing it"
                )
                XCTAssertEqual(
                    Self.occurrences(of: ".lineLimit(1)", in: body), labels,
                    """
                    \(name)'s \(builder) draws its Text labels inside a fixed-height header strip, \
                    and each must carry its own .lineLimit(1) — an older occurrence elsewhere in the \
                    file does not protect this one
                    """
                )
            }
        }
    }

    // MARK: - Rule twelve: the dock's tab row is configured in one place

    /// The dock's tab row is drawn once, above whichever panel is showing, from
    /// `ContentView.panelContent(_:)` — the one place every panel passes
    /// through, inside the fixed-height slot.
    ///
    /// Swift's `internal` cannot stop a panel file from naming the row, and a
    /// second call site would compile and look deliberate: a panel drawing its
    /// own copy would show two rows stacked in the slot, or one row where the
    /// host's had been removed and five panels with none. So reachability is
    /// pinned instead, over stripped source: the set of files naming the
    /// `DockTabRow` token equals the row's own file (which declares it) and
    /// `ContentView.swift`; the window root constructs it — `DockTabRow(` —
    /// exactly once, inside `panelContent(`'s brace-matched body; and none of
    /// the six hosted panel files names the type at all, which the set already
    /// implies and is asserted per file so the failure names the panel.
    private static let dockTabRowFile = "DockTabRow.swift"

    /// The six views `panelContent(_:)` puts in the slot, one per panel.
    private static let hostedPanelFiles = [
        "TerminalPanelView.swift",
        "CommitLogView.swift",
        "LocalChangesView.swift",
        "ProblemsPanelView.swift",
        "UsagesPanelView.swift",
        "PullRequestsPanelView.swift",
    ]

    func testTheDockTabRowIsConfiguredInOnePlace() throws {
        var namers: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if LSPSourceGatingTests.containsToken("DockTabRow", in: code) {
                namers.insert(url.lastPathComponent)
            }
            if Self.hostedPanelFiles.contains(url.lastPathComponent) {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken("DockTabRow", in: code),
                    """
                    \(url.lastPathComponent) names DockTabRow — the row is the host's, drawn once \
                    above every panel, and a panel drawing its own stacks a second one in the slot
                    """
                )
            }
        }
        XCTAssertEqual(
            namers, [Self.dockTabRowFile, Self.windowRootFile],
            "DockTabRow must be named only in its own file and in \(Self.windowRootFile)"
        )

        let root = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: Self.windowRootFile))
        )
        XCTAssertEqual(
            Self.occurrences(of: "DockTabRow(", in: root), 1,
            "\(Self.windowRootFile) must construct the dock's tab row exactly once"
        )
        let slot = try XCTUnwrap(
            Self.matchedBody(after: "func panelContent(", in: root),
            "panelContent( is gone or renamed — re-point this rule rather than losing it"
        )
        XCTAssertTrue(
            slot.contains("DockTabRow("),
            """
            the dock's tab row must be constructed inside panelContent(_:) — the one place \
            every panel passes through, inside the fixed-height slot
            """
        )
    }

    // MARK: - Rule thirteen: every dock tab and the close action are identifiable without sight

    /// Rule ten read one strip up. A dock tab's selection is drawn as an accent
    /// strip — a shape, not a word — so the tab must hide that strip *and* speak
    /// the selection as its value, or the one fact that distinguishes the panel
    /// on screen is invisible to anyone not looking. It must also carry its
    /// panel's name as an explicit label, so what is announced is the table's
    /// name rather than whatever the label's children fold together.
    ///
    /// The close action is an icon-only `xmark`, the case rule ten exists for: a
    /// `Button` combines its children, so without an explicit label it
    /// announces the glyph's own name — and `.help(` is a tooltip, not a name.
    ///
    /// Read over the **brace-matched bodies** of the two builders, both named
    /// here so renaming either fails loudly rather than leaving the rule to pass
    /// over a body it can no longer find.
    private static let dockTabBuilder = "func tabButton("
    private static let dockCloseBuilder = "var closeButton"

    func testEveryDockTabAndTheCloseActionCarryAName() throws {
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: Self.dockTabRowFile))
        )
        let requirements = [
            (Self.dockTabBuilder, [".accessibilityLabel(", ".accessibilityValue(", ".accessibilityHidden(true)"]),
            (Self.dockCloseBuilder, [".help(", ".accessibilityLabel("]),
        ]
        for (builder, required) in requirements {
            let body = try XCTUnwrap(
                Self.matchedBody(after: builder, in: code),
                "\(Self.dockTabRowFile)'s \(builder) is gone or renamed — re-point this rule rather than losing it"
            )
            for modifier in required {
                XCTAssertTrue(
                    body.contains(modifier),
                    """
                    \(Self.dockTabRowFile)'s \(builder) must spell \(modifier) — a dock control is \
                    named after its glyph, and a selection drawn as a shape is unspoken, until \
                    an explicit label and value replace them
                    """
                )
            }
        }
    }

    // MARK: - Rule fourteen: the dock's swept surfaces draw their own rules

    /// The dock's swept files draw every separating line themselves, as a
    /// one-point `hairline` rectangle overlaid on the edge the surface owns —
    /// part two's breadcrumb and part three's bar and dividers precedent — and
    /// spell no `Divider(` at all.
    ///
    /// A platform separator is wrong here for rule one's reason read through a
    /// view instead of a colour: `Divider()` draws the *system's* separator
    /// colour at the system's thickness, a step off the `hairline` role the row
    /// above and the panel beside it draw with, in either appearance. It
    /// compiles, it looks plausible, and it is the one line in a restyled panel
    /// that still reads the platform's palette. It is also a line *between* two
    /// views, owned by neither, where the sweep's rule is that the surface that
    /// owns an edge draws it.
    ///
    /// A named list rather than the whole gated set: the files outside the dock
    /// were swept under their own parts. Part four (b) added the dock's
    /// remaining panels — the Log, Local Changes and Pull Requests panels, the
    /// diff pane they open — and the Log's filter bar.
    ///
    /// The diff pane is AppKit, where the platform's separator is an `NSBox`
    /// rather than a `Divider()`, so `DiffView.swift` must spell neither.
    private static let dockRuleOwners = [
        "DockTabRow.swift",
        "ProblemsPanelView.swift",
        "UsagesPanelView.swift",
        "TerminalPanelView.swift",
        "CommitLogView.swift",
        "LocalChangesView.swift",
        "PullRequestsPanelView.swift",
        "DiffView.swift",
        "LogFilterBar.swift",
    ]

    /// The AppKit dock surface, held to the platform separator's AppKit spelling.
    private static let appKitDockRuleOwner = "DiffView.swift"

    func testTheDocksSweptSurfacesDrawTheirOwnRules() throws {
        for name in Self.dockRuleOwners {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            XCTAssertFalse(
                code.contains("Divider("),
                """
                \(name) spells Divider( — a swept dock surface draws its own one-point hairline \
                on the edge it owns, never the platform's separator
                """
            )
        }
        let pane = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: Self.appKitDockRuleOwner))
        )
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("NSBox", in: pane),
            """
            \(Self.appKitDockRuleOwner) spells NSBox — the AppKit platform separator draws the \
            system's colour, a step off the hairline role; draw the rule as the surface's own
            """
        )
    }

    // MARK: - Rule fifteen: the severity mapping is Core's one answer

    /// Which chrome role a diagnostic severity is drawn in has one answer,
    /// `ChromeColorRole.diagnosticRole(for:)` in Core, read by the gutter's
    /// severity dot and by the Problems panel's badges and row glyphs.
    ///
    /// The regression it prevents is a **second severity table reappearing in a
    /// view**: the mapping used to live in the ruler while the panel read the
    /// code zone's own table, and a view that grows its own `switch` again
    /// compiles, draws four plausible colours and drifts from the gutter's the
    /// first time either side is touched. So, over stripped source:
    ///
    /// - no app file declares `func diagnosticRole` (the answer is Core's);
    /// - the set of app files spelling `diagnosticRole(for:` equals the two known
    ///   readers — a third reader is a deliberate edit here, not an accident;
    /// - `ProblemsPanelView.swift` names no `SyntaxTheme`, whose severity table
    ///   belongs to the squiggle under the text and to the code zone alone;
    /// - no gated file spells a severity **case label** — `case` followed, on
    ///   the same line, by `.error`, `.warning`, `.information` or `.hint`, or
    ///   the qualified `DiagnosticSeverity.` spelling of any of the four. That is
    ///   the table's shape rather than its name: a local `switch` returning roles
    ///   passes the three clauses above, and any one of the four labels is enough
    ///   to fail this one, so a mapping handling three of the four (with a
    ///   `default`) is caught as well.
    ///
    /// The one severity `switch` a gated file may keep is
    /// `ProblemsPanelView.swift`'s `severitySymbol`, a **glyph** table — which
    /// SF Symbol a row draws, no colour — named here by its declaration so a
    /// rename fails loudly; its body is cut out before the labels are looked for,
    /// and must itself name no colour (`theme`, `ChromeColorRole`, `Color`).
    ///
    /// What the last clause cannot see, stated rather than implied: a dictionary
    /// literal keyed by the same values (`[.error: .statusRed]`), a chain of
    /// `==` comparisons, and a `case` list continued onto a second line past its
    /// first label. It sees a `switch`'s labels, which is the shape the
    /// regression took before; a rule claiming more than that would be the
    /// defect it exists to prevent.
    private static let severityReaders: Set<String> = [
        "LineNumberRulerView.swift",
        "ProblemsPanelView.swift",
    ]

    /// The glyph table the severity-label clause exempts, by file and
    /// declaration.
    private static let severityGlyphTable = (
        file: "ProblemsPanelView.swift",
        declaration: "private var severitySymbol: String"
    )

    func testTheSeverityMappingIsCoresOneAnswer() throws {
        var readers: Set<String> = []
        for url in try Self.swiftSources() where url.path.contains("/Sources/Pisaka/") {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertFalse(
                code.contains("func diagnosticRole"),
                "\(name) declares its own diagnosticRole — the severity mapping is Core's one answer"
            )
            if code.contains("diagnosticRole(for:") {
                readers.insert(name)
            }
        }
        XCTAssertEqual(
            readers, Self.severityReaders,
            "the app files reading ChromeColorRole.diagnosticRole(for:) must be exactly its two known readers"
        )

        let panel = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "ProblemsPanelView.swift"))
        )
        XCTAssertFalse(
            LSPSourceGatingTests.containsToken("SyntaxTheme", in: panel),
            """
            ProblemsPanelView.swift names SyntaxTheme — the panel is chrome and reads the severity's \
            role; SyntaxTheme's table is the squiggle's alone
            """
        )

        let labels = try NSRegularExpression(
            pattern: "\\bcase\\b[^:\\n]*\\.(error|warning|information|hint)\\b"
                + "|\\bDiagnosticSeverity\\.(error|warning|information|hint)\\b"
        )
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            var code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if name == Self.severityGlyphTable.file {
                let declaration = Self.severityGlyphTable.declaration
                let glyphs = try XCTUnwrap(
                    Self.matchedBody(after: declaration, in: code),
                    "\(name) no longer declares `\(declaration)` — update the exemption rather than losing it"
                )
                for colour in ["theme", "ChromeColorRole", "Color"] {
                    XCTAssertFalse(
                        LSPSourceGatingTests.containsToken(colour, in: glyphs),
                        "\(name)'s severity glyph table names \(colour) — it answers a symbol, never a colour"
                    )
                }
                code = code.replacingOccurrences(of: glyphs, with: "")
            }
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(
                labels.firstMatch(in: code, range: range),
                """
                \(name) spells a DiagnosticSeverity case label — a severity mapping in a view is a second \
                table; read ChromeColorRole.diagnosticRole(for:)
                """
            )
        }
    }

    // MARK: - Rule sixteen: an indicator strip's bottom rule is drawn behind it

    /// The strips whose tabs draw an accent indicator on the strip's own bottom
    /// edge: the tab strip above the editor and the dock's tab row.
    ///
    /// The defect this pins is one point tall. Such a strip also draws its own
    /// one-point `hairline` along that same edge, and when the rule was an
    /// `.overlay(alignment: .bottom)` on the strip it was drawn **on top of**
    /// every tab — an overlay covers its whole content — so the selected tab
    /// showed one point of accent over one point of grey instead of its
    /// two-point bar, and the tab strip's active tab, filled in the editor's own
    /// background to merge into it, was cut off from the editor by the very
    /// rule its comment said it sat above. Nothing in the compiler or in a
    /// headless test can see a one-point overlap, and it looks nearly right.
    ///
    /// So, over stripped source, in each listed file: no
    /// `.overlay(alignment: .bottom)` whose brace-matched body names `hairline`,
    /// and at least one `.background(alignment: .bottom)` whose body does — the
    /// second half so the first cannot pass on a strip that lost its rule
    /// altogether. An overlay at the bottom that draws the *accent* itself (the
    /// tab strip's cell does) is the indicator, not the rule, and is allowed.
    ///
    /// A named list, rule fourteen's shape: a third strip with a bottom-edge
    /// indicator is added here as part of drawing it, rather than left unguarded.
    private static let indicatorStripFiles = [
        "TabStripView.swift",
        "DockTabRow.swift",
    ]

    func testAnIndicatorStripsBottomRuleIsDrawnBehindItsTabs() throws {
        for name in Self.indicatorStripFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            let overlays = Self.matchedBodies(after: ".overlay(alignment: .bottom)", in: code)
            XCTAssertFalse(
                overlays.contains { LSPSourceGatingTests.containsToken("hairline", in: $0) },
                """
                \(name) overlays its bottom hairline — an overlay paints over the active tab's \
                accent indicator; draw the rule with .background(alignment: .bottom) instead
                """
            )
            let backgrounds = Self.matchedBodies(after: ".background(alignment: .bottom)", in: code)
            XCTAssertTrue(
                backgrounds.contains { LSPSourceGatingTests.containsToken("hairline", in: $0) },
                "\(name) draws no bottom hairline behind its tabs — re-point this rule rather than losing it"
            )
        }
    }

    /// Every trailing-closure body following an occurrence of `declaration`, in
    /// order — `matchedBody(after:in:)` read at each occurrence rather than the
    /// first alone.
    ///
    /// Every caller names a *modifier*, whose closure opens immediately after
    /// it, so an occurrence followed by anything but whitespace before its `{` is
    /// skipped rather than bound to whichever block comes next in the file — a
    /// body "somewhere later" is another construct's, and a rule reading it
    /// passes or fails on text it does not name.
    private static func matchedBodies(after declaration: String, in code: String) -> [String] {
        var bodies: [String] = []
        var rest = Substring(code)
        while let found = rest.range(of: declaration) {
            let gap = rest[found.upperBound...].prefix { $0 != "{" }
            if gap.allSatisfy(\.isWhitespace), gap.endIndex < rest.endIndex {
                let tail = String(rest[found.lowerBound...])
                if let body = matchedBody(after: declaration, in: tail) { bodies.append(body) }
            }
            rest = rest[found.upperBound...]
        }
        return bodies
    }

    // MARK: - Rule seventeen: the changed-file status mapping is Core's one answer

    /// Which letter a changed file's status is drawn as, and in which role, has
    /// one answer in Core — `FileStatus.letter` and
    /// `ChromeColorRole.changedFileRole(for:)` — read by the Log's changed-file
    /// rows, Local Changes' rows and the commit dialog's file list.
    ///
    /// Before part four (b) the mapping was written out twice, byte for byte —
    /// once in the Log's detail pane and once in Local Changes, whose internal
    /// helpers the commit dialog called rather than keeping a third copy. The two
    /// had not drifted; the rule exists so they cannot: a view growing its own
    /// `switch` again compiles, draws six plausible colours and disagrees with
    /// the panel beside it the first time either is touched, and a third table is
    /// the copy nobody remembers to update. Rule fifteen's shape, over stripped
    /// source:
    ///
    /// - no app file declares `func changedFileRole` or a `letter` table
    ///   (`var letter` / `func letter`);
    /// - the app files spelling `changedFileRole(for:` equal the three known
    ///   readers — the commit dialog is one although it is not yet gated, since
    ///   it shares the answer rather than keeping a fourth copy;
    /// - no gated file spells a status case label — `case` followed, on the same
    ///   line, by `.renamed`, `.untracked` or `.conflicted` — or qualifies any
    ///   status case as `FileStatus.`.
    ///
    /// Stated limit: `.added`, `.modified` and `.deleted` are also the diff
    /// kinds' case names (`DiffRowKind`, `UnifiedDiffLine.Kind`), which the diff
    /// surfaces legitimately switch over, so a bare label naming one of those
    /// three is not matched; a status table must name one of the other three to
    /// be caught, and one is enough. Rule fifteen's other limits apply as stated
    /// there: a dictionary literal, an `==` chain, a `case` list continued past
    /// its first line.
    private static let changedFileRoleReaders: Set<String> = [
        "CommitLogView.swift",
        "LocalChangesView.swift",
        "CommitDialogView.swift",
    ]

    func testTheChangedFileStatusMappingIsCoresOneAnswer() throws {
        let letterTable = try NSRegularExpression(pattern: "\\b(var|func)\\s+letter\\b")
        var readers: Set<String> = []
        for url in try Self.swiftSources() where url.path.contains("/Sources/Pisaka/") {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertFalse(
                code.contains("func changedFileRole"),
                "\(name) declares its own changedFileRole — the status colour is Core's one answer"
            )
            XCTAssertNil(
                letterTable.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                "\(name) declares its own status letter table — read FileStatus.letter"
            )
            if code.contains("changedFileRole(for:") { readers.insert(name) }
        }
        XCTAssertEqual(
            readers, Self.changedFileRoleReaders,
            "the app files reading ChromeColorRole.changedFileRole(for:) must be exactly its three known readers"
        )

        let labels = try NSRegularExpression(
            pattern: "\\bcase\\b[^:\\n]*\\.(renamed|untracked|conflicted)\\b"
                + "|\\bFileStatus\\.(modified|added|deleted|renamed|untracked|conflicted)\\b"
        )
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertNil(
                labels.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                """
                \(url.lastPathComponent) spells a FileStatus case label — a status mapping in a view is a \
                second table; read FileStatus.letter and ChromeColorRole.changedFileRole(for:)
                """
            )
        }
    }

    // MARK: - Rule eighteen: the checks-state mapping is Core's one answer

    /// Which glyph, words and role a pull request's checks state is drawn with
    /// has one answer in Core — `GitHubChecksSummary`'s `symbolName` /
    /// `spokenWords`, `GitHubCheckBucket`'s `spokenWords` (a job row draws a dot,
    /// not a glyph) and `ChromeColorRole.checksRole(for:)` — read
    /// by the bottom-bar indicator and the Pull Requests panel, which used to
    /// keep one table each and could disagree about the same pull request.
    ///
    /// Over stripped source: no app file declares `func checksRole`; the app
    /// files spelling `checksRole(for:` equal the two known readers; and no gated
    /// file spells a checks case label — `case` followed on the same line by
    /// `.noChecks`, `.pending`, `.failure`, `.success`, `.pass`, `.fail`,
    /// `.skipping` or `.cancel` — or qualifies one as `GitHubChecksSummary.` or
    /// `GitHubCheckBucket.`.
    ///
    /// Stated limit: rule fifteen's — the clause sees a `switch`'s labels, not a
    /// dictionary literal keyed by the same values, a chain of `==` comparisons,
    /// or a `case` list continued past its first line.
    private static let checksRoleReaders: Set<String> = [
        "PullRequestIndicatorView.swift",
        "PullRequestsPanelView.swift",
    ]

    func testTheChecksStateMappingIsCoresOneAnswer() throws {
        var readers: Set<String> = []
        for url in try Self.swiftSources() where url.path.contains("/Sources/Pisaka/") {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertFalse(
                code.contains("func checksRole"),
                "\(name) declares its own checksRole — the checks colour is Core's one answer"
            )
            if code.contains("checksRole(for:") { readers.insert(name) }
        }
        XCTAssertEqual(
            readers, Self.checksRoleReaders,
            "the app files reading ChromeColorRole.checksRole(for:) must be exactly its two known readers"
        )

        let cases = "(noChecks|pending|failure|success|pass|fail|skipping|cancel)"
        let labels = try NSRegularExpression(
            pattern: "\\bcase\\b[^:\\n]*\\.\(cases)\\b"
                + "|\\b(GitHubChecksSummary|GitHubCheckBucket)\\.\(cases)\\b"
        )
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertNil(
                labels.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                """
                \(url.lastPathComponent) spells a checks-state case label — a checks mapping in a view is a \
                second table; read the Core glyph, words and ChromeColorRole.checksRole(for:)
                """
            )
        }
    }

    // MARK: - Rule nineteen: the diff row wash is Core's one answer, and a diff side one type

    /// Which role a diff row is washed in — and which marker the gutter draws —
    /// has one answer in Core, `ChromeColorRole.diffWashRole(for:…)` and
    /// `diffMarkerRole(for:side:)`, read by the side-by-side pane and the unified
    /// diff. Both used to compose their own tint by alpha over a system colour,
    /// each with its own opacity, so the same added line was two greens.
    ///
    /// Over stripped source:
    ///
    /// - no app file other than the palette names `diffAddedBackground` or
    ///   `diffRemovedBackground` — the table gives each role its value, and every
    ///   drawing site reaches them through the Core answer;
    /// - no app file declares `func diffWashRole` or `func diffMarkerRole`;
    /// - the app files spelling `diffWashRole(for:` equal the two readers;
    /// - neither reader spells `withAlphaComponent(` or `.opacity(` — the wash's
    ///   alpha is the palette's, one value over either background.
    ///
    /// **A macOS diff side is one type**, Core's `DiffSide`: neither reader
    /// declares an `enum Side`, and no file under `Sources/Pisaka` outside
    /// `Sources/Pisaka/iOS/` spells `DiffTextView.Side` — the old type's
    /// qualified name, which a new macOS caller would bring back with it.
    ///
    /// Both limits are stated rather than implied. The iOS diff view keeps a
    /// private `Side` of its own: it has no chrome palette to read and is not
    /// gated, so it is not the duplicate this rule is about. And Core's private
    /// `ThreeWayMerge.Side` names *merge* sides (ours/theirs), not diff sides —
    /// a different question — so the clause never reads `Sources/PisakaCore`.
    private static let diffWashReaders: Set<String> = [
        "DiffView.swift",
        "CommitUnifiedDiffView.swift",
    ]

    func testTheDiffWashIsCoresOneAnswerAndADiffSideIsOneType() throws {
        var readers: Set<String> = []
        for url in try Self.swiftSources() where url.path.contains("/Sources/Pisaka/") {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if name != "ChromePalette.swift" {
                for role in ["diffAddedBackground", "diffRemovedBackground"] {
                    XCTAssertFalse(
                        LSPSourceGatingTests.containsToken(role, in: code),
                        "\(name) names \(role) directly — a diff wash is ChromeColorRole.diffWashRole(for:)'s answer"
                    )
                }
            }
            for declaration in ["func diffWashRole", "func diffMarkerRole"] {
                XCTAssertFalse(
                    code.contains(declaration),
                    "\(name) declares its own \(declaration) — the diff wash is Core's one answer"
                )
            }
            if code.contains("diffWashRole(for:") { readers.insert(name) }
            if !url.path.contains("/Sources/Pisaka/iOS/") {
                XCTAssertFalse(
                    code.contains("DiffTextView.Side"),
                    """
                    \(name) spells DiffTextView.Side — a macOS diff side is Core's DiffSide, one type with \
                    no mapping site to drift (the iOS view's private Side is not gated and is not this)
                    """
                )
            }
        }
        XCTAssertEqual(
            readers, Self.diffWashReaders,
            "the app files reading ChromeColorRole.diffWashRole(for:) must be exactly its two known readers"
        )

        let sideEnum = try NSRegularExpression(pattern: "\\benum\\s+Side\\b")
        for name in Self.diffWashReaders.sorted() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            for alpha in ["withAlphaComponent(", ".opacity("] {
                XCTAssertFalse(
                    code.contains(alpha),
                    "\(name) spells \(alpha) — a diff wash's alpha is the palette's, not a second one composed here"
                )
            }
            XCTAssertNil(
                sideEnum.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                "\(name) declares an enum Side — a macOS diff side is Core's DiffSide"
            )
        }
    }

    // MARK: - Rule twenty: the three panels' controls are identifiable without sight

    /// Rule ten read over the Log, Local Changes and Pull Requests panels.
    ///
    /// Each panel's controls are named here by builder — a brace-matched body
    /// found by its declaration, narrowed through a path where the builder is a
    /// type's `body` — and each carries what it owes:
    ///
    /// - an **icon-only control** (the refresh glyphs, the grouping segments, the
    ///   open-in-browser and dismiss glyphs) spells `.accessibilityLabel(`, since
    ///   without one it is announced as its glyph;
    /// - a **state carrier** — the checks glyph, the status letter (spoken as the
    ///   row's value in the Log, as its own in Local Changes), the checkbox and
    ///   the disclosure chevrons — spells `.accessibilityValue(`, since a colour
    ///   or a shape is unspoken;
    /// - inside a **labelled control's** body every `Image(systemName:` carries
    ///   an `.accessibilityHidden(true)` of its own — in the modifier chain
    ///   applied to the image itself, or in the chain applied to a container
    ///   brace-enclosing it, which in SwiftUI hides its children too — since an
    ///   unhidden symbol folds its own name into the control's.
    ///
    /// The checks glyph is the one entry not held to the last clause: the image
    /// *is* the element, named and valued outright. A renamed builder fails
    /// loudly rather than narrowing the rule to nothing.
    ///
    /// The binding is the rule's substance. Its first shape searched all of the
    /// text after each image, so the dismiss glyph's modifier in `endingStrip`
    /// satisfied the warning glyph before it: removing the warning's own
    /// `.accessibilityHidden(true)` stayed green while that symbol became an
    /// extra announcement. A chain is read as postfix `.name(…)` links (a
    /// same-line trailing closure included) and ends at the first token that is
    /// not one — the next sibling view. Stated limit: a container hidden by a
    /// modifier applied *outside* the builder's own text is not seen, and fails
    /// loudly rather than passing.
    private struct ControlBuilder {
        let path: [String]
        let required: [String]
        let hidesSymbols: Bool
    }

    private static let panelControlBuilders: [(file: String, builders: [ControlBuilder])] = [
        ("CommitLogView.swift", [
            ControlBuilder(path: ["private var header: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["private struct CommitFileRow", "var body: some View"],
                           required: [".accessibilityValue("], hidesSymbols: true),
        ]),
        ("LocalChangesView.swift", [
            ControlBuilder(path: ["private var toolbar: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["private func groupingSegment("],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["private var folderHeader: some View"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
            ControlBuilder(path: ["private struct ChangedFileRow", "var body: some View"],
                           required: [".accessibilityValue("], hidesSymbols: true),
            ControlBuilder(path: ["private var checkbox: some View"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
        ]),
        ("PullRequestsPanelView.swift", [
            ControlBuilder(path: ["private var header: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["private func endingStrip("],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["private var summaryLine: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["private var disclosure: some View"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
            ControlBuilder(path: ["private var checksMark: some View"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: false),
            ControlBuilder(path: ["private func checkRow("],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
        ]),
        ("ChromeControls.swift", [
            ControlBuilder(path: ["struct ChromeQueryToggle"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: false),
        ]),
        ("SearchBarView.swift", [
            ControlBuilder(path: ["private var findRow: some View"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
            ControlBuilder(path: ["private var replaceRow: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: false),
        ]),
        ("ProjectSearchView.swift", [
            ControlBuilder(path: ["private var queryRow: some View"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
            ControlBuilder(path: ["private var replaceRow: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: false),
        ]),
    ]

    func testThePanelsControlsAreIdentifiableWithoutSight() throws {
        for (name, builders) in Self.panelControlBuilders {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            for builder in builders {
                var body: String? = code
                for step in builder.path {
                    body = body.flatMap { Self.matchedBody(after: step, in: $0) }
                }
                let described = builder.path.joined(separator: " › ")
                let found = try XCTUnwrap(
                    body,
                    "\(name)'s \(described) is gone or renamed — re-point this rule rather than losing it"
                )
                for modifier in builder.required {
                    XCTAssertTrue(
                        found.contains(modifier),
                        """
                        \(name)'s \(described) must spell \(modifier) — a panel control is named after its \
                        glyph, and a state drawn as a colour or a shape is unspoken, until an explicit label \
                        and value replace them
                        """
                    )
                }
                guard builder.hidesSymbols else { continue }
                var searchFrom = found.startIndex
                while let symbol = found.range(of: "Image(systemName:", range: searchFrom..<found.endIndex) {
                    searchFrom = symbol.upperBound
                    XCTAssertTrue(
                        Self.isHiddenByItsOwnChain(imageAt: symbol.lowerBound, in: found),
                        """
                        \(name)'s \(described) draws an Image(systemName:) whose own modifier chain — and \
                        every enclosing container's — carries no .accessibilityHidden(true); an unhidden \
                        symbol folds its own name into the labelled control's
                        """
                    )
                }
            }
        }
    }

    /// Whether the image starting at `image` is hidden by a modifier that is
    /// *its own*: one in the chain applied to the image itself, or in the chain
    /// applied to a container brace-enclosing it within `code`. A later sibling's
    /// modifier is in neither — which is the case the rule's first shape, a search
    /// of all the remaining text, accepted.
    private static func isHiddenByItsOwnChain(imageAt image: String.Index, in code: String) -> Bool {
        let hidden = ".accessibilityHidden(true)"
        guard let open = code[image...].firstIndex(of: "("),
              let callEnd = balancedEnd(from: open, in: code) else { return false }
        if modifierChain(from: callEnd, in: code).contains(hidden) { return true }
        var depth = 0
        var index = image
        while index > code.startIndex {
            index = code.index(before: index)
            if code[index] == "}" { depth += 1 }
            if code[index] == "{" {
                if depth > 0 { depth -= 1; continue }
                guard let blockEnd = balancedEnd(from: index, in: code) else { return false }
                if modifierChain(from: blockEnd, in: code).contains(hidden) { return true }
            }
        }
        return false
    }

    /// The index just past the bracket matching the one at `open` (`(` or `{`).
    private static func balancedEnd(from open: String.Index, in code: String) -> String.Index? {
        let opening = code[open]
        let closing: Character = opening == "(" ? ")" : "}"
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == opening { depth += 1 }
            if code[index] == closing {
                depth -= 1
                if depth == 0 { return code.index(after: index) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The postfix modifier chain starting at `start` — `.name`, optionally
    /// followed by a parenthesised argument list and a same-line trailing
    /// closure, repeated — and nothing past its last link. A sibling view on the
    /// next line starts with no dot, which is where the chain ends.
    private static func modifierChain(from start: String.Index, in code: String) -> Substring {
        var index = start
        var end = start
        func skip(_ allowed: (Character) -> Bool) {
            while index < code.endIndex, allowed(code[index]) { index = code.index(after: index) }
        }
        while true {
            skip { $0.isWhitespace }
            guard index < code.endIndex, code[index] == "." else { break }
            index = code.index(after: index)
            skip { $0.isLetter || $0.isNumber || $0 == "_" }
            if index < code.endIndex, code[index] == "(" {
                guard let past = balancedEnd(from: index, in: code) else { break }
                index = past
            }
            end = index
            skip { $0 == " " || $0 == "\t" }
            if index < code.endIndex, code[index] == "{" {
                guard let past = balancedEnd(from: index, in: code) else { break }
                index = past
                end = index
            }
        }
        return code[start..<end]
    }

    // MARK: - Rule twenty-one: the Log's filter bar fits the window it lives in

    /// The requirement, stated in `LogFilterBar.swift`'s own doc comment: at the
    /// main window's minimum width (`metrics.scaled(640)`), at every interface
    /// scale, every control in the filter bar is reachable and nothing is
    /// clipped.
    ///
    /// The defect this pins shipped once. Part four (b) redrew the bar as one
    /// row whose fields stated fixed widths (`.frame(width:)` at 140, 160 and
    /// 220) beside a branch menu and two date bounds forced to their intrinsic
    /// widths, so the row could not shrink below roughly 1000 points at scale 1
    /// — and between that and the window's 640 the panel column clipped it, and
    /// the branch menu, the message search, the Log header's refresh button and
    /// the commit rows' date column went out of reach. Nothing else in the
    /// pipeline can see it: it compiles, it renders perfectly at the width the
    /// reviewer happens to use, and no headless test lays out a SwiftUI row.
    ///
    /// What *is* textually visible is the shape of the fix, so that is what is
    /// pinned, over stripped source: the file states no fixed `.frame(width:` at
    /// all — a width in it is a `minWidth`/`idealWidth`/`maxWidth` — and the row
    /// is drawn a second time inside a horizontal `ScrollView`, the branch that
    /// keeps every control reachable once the minimums no longer compose.
    /// Neither half proves the layout; each is the half that went missing.
    ///
    /// The fixed width is matched as a regular expression — `width:` as the
    /// `.frame(`'s first argument whatever whitespace and newlines sit between
    /// them — and not as a contiguous substring, because the file writes every
    /// width site as a multi-line `.frame(` carrying three keys. The regression
    /// this rule exists to catch therefore arrives as one of those keys being
    /// changed to `width:`, not as a fresh single-line call; a contiguous match
    /// saw only the historical spelling. The key must be exactly `width` — the
    /// match starts right after the parenthesis and its whitespace, so
    /// `minWidth:`, `idealWidth:` and `maxWidth:` never satisfy it.
    func testTheLogFilterBarStatesNoFixedWidthAndScrollsBelowItsFloor() throws {
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "LogFilterBar.swift"))
        )
        let fixedWidth = try NSRegularExpression(pattern: #"\.frame\(\s*width\s*:"#)
        XCTAssertNil(
            fixedWidth.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
            """
            LogFilterBar.swift states a fixed .frame(width: — a control that cannot shrink clips the \
            row below the window's minimum width; state minWidth/maxWidth instead
            """
        )
        XCTAssertTrue(
            code.contains("ScrollView(.horizontal"),
            """
            LogFilterBar.swift draws its row in no horizontal ScrollView — below the floor its \
            minimums compose, the row must scroll rather than clip
            """
        )
    }

    // MARK: - Rule twenty-two: a pushed resize cursor does not outlive its view

    /// The functions, per gated file, that push an `NSCursor` — pinned by
    /// equality so a scanner that stopped finding them fails instead of passing
    /// vacuously, and a new hand-rolled divider joins the rule deliberately.
    static let cursorPushingFunctions: Set<String> = [
        "CommitLogView.swift: syncDivideCursor",
        "ContentView.swift: syncPanelDividerCursor",
        "ContentView.swift: syncMarkdownDividerCursor",
    ]

    /// A hand-rolled divider pushes the resize cursor from hover and drag state
    /// and pops it from `onHover(false)` or the drag's `onEnded`. Neither arrives
    /// when the divider leaves the tree with the pointer on it or mid-drag — the
    /// Log's list/detail divide exists only while a commit is selected, the model
    /// clears the selection on its refresh paths, and a dock tab switch takes the
    /// whole panel away — and `NSCursor`'s stack is global, so the cursor stays
    /// pushed after the flag that would have balanced it is gone. The defect
    /// shipped once, in the Log's divide; the two `ContentView` dividers already
    /// released from `onDisappear`, which is the rule this states for all three.
    ///
    /// Over stripped source, in every gated file: each function whose body
    /// pushes an `NSCursor` is called from inside an `.onDisappear {` block in the
    /// same file, and every `.push()` in the file sits inside such a function —
    /// so a push added inline, beside the sync function rather than through it,
    /// fails too. Stated limit: the rule sees the *call*, not that the handler
    /// clears the hover and drag state before it; a handler calling the sync with
    /// both still set would pop nothing. That half is not expressible honestly
    /// over text, and each handler's own comment says why it clears both.
    func testAPushedResizeCursorIsReleasedWhenItsViewDisappears() throws {
        var found: Set<String> = []
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let file = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            guard code.contains("NSCursor") else { continue }

            let declarations = try NSRegularExpression(pattern: "func ([A-Za-z0-9_]+)\\(")
            let range = NSRange(code.startIndex..<code.endIndex, in: code)
            var pushesInFunctions = 0
            // The declaration stops short of the brace: `matchedBody(after:in:)`
            // brace-matches from the first `{` *after* what it is given.
            let disappearances = Self.matchedBodies(after: ".onDisappear ", in: code)
            for match in declarations.matches(in: code, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: code) else { continue }
                let name = String(code[nameRange])
                guard let body = Self.matchedBody(after: "func \(name)(", in: code),
                      body.contains("NSCursor"), body.contains(".push()") else { continue }
                found.insert("\(file): \(name)")
                pushesInFunctions += Self.occurrences(of: ".push()", in: body)
                XCTAssertTrue(
                    disappearances.contains { $0.contains("\(name)(") },
                    """
                    \(file): \(name) pushes an NSCursor but no .onDisappear { block calls it — a view \
                    leaving the tree with the pointer on it, or mid-drag, gets neither onHover(false) nor \
                    onEnded, and the cursor stays pushed after its flag is gone
                    """
                )
            }
            XCTAssertEqual(
                Self.occurrences(of: ".push()", in: code), pushesInFunctions,
                "\(file) pushes an NSCursor outside the sync function a disappearance handler can reach"
            )
        }
        XCTAssertEqual(
            found, Self.cursorPushingFunctions,
            "the gated files' cursor-pushing functions changed — pin the new set deliberately"
        )
    }

    // MARK: - Rule twenty-three: a popover surface names bgPopover

    /// The gated files that draw a popover surface on `bgPopover`.
    private static let bgPopoverReaders: Set<String> = [
        "CompletionPanel.swift",
        "HoverPanel.swift",
        "BranchSwitcherView.swift",
        "ProjectSwitcherView.swift",
        "LogFilterBar.swift",
    ]

    func testPopoverSurfaceNamesBgPopover() throws {
        var readers: Set<String> = []
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            if name == "ChromePalette.swift" { continue }
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if LSPSourceGatingTests.containsToken("bgPopover", in: code) {
                readers.insert(name)
            }
        }
        XCTAssertEqual(
            readers, Self.bgPopoverReaders,
            "the gated files naming bgPopover must be exactly its five popover surfaces"
        )

        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let presentsPopover = code.contains(".popover(") || LSPSourceGatingTests.containsToken("NSPanel", in: code)
            if presentsPopover {
                XCTAssertTrue(
                    Self.bgPopoverReaders.contains(name),
                    "\(name) presents a popover (.popover( or NSPanel) but does not name bgPopover — a popover surface must be drawn on bgPopover"
                )
            }
        }

        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertFalse(
                code.contains("NSVisualEffectView"),
                "\(name) spells NSVisualEffectView — a popover surface is a flat bgPopover fill, not a material"
            )
            XCTAssertFalse(
                code.contains(".material"),
                "\(name) spells .material — a popover surface is a flat bgPopover fill, not a material"
            )
            XCTAssertFalse(
                code.contains("presentationBackground"),
                "\(name) spells presentationBackground — popover ground goes on the content as a background, with no availability branch"
            )
        }
    }

    // MARK: - Rule twenty-four: Divider() in exactly one place

    func testDividerInExactlyOnePlace() throws {
        let dividerPattern = try NSRegularExpression(pattern: "\\bDivider\\s*\\(")
        var owners: Set<String> = []
        var counts: [String: Int] = [:]
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let range = NSRange(code.startIndex..., in: code)
            let count = dividerPattern.numberOfMatches(in: code, range: range)
            if count > 0 {
                owners.insert(url.lastPathComponent)
                counts[url.lastPathComponent] = count
            }
        }
        XCTAssertEqual(
            owners, ["SearchHistoryMenu.swift"],
            "the gated files spelling Divider( must be exactly the menu — a swept surface draws its own hairline"
        )
        XCTAssertEqual(
            counts["SearchHistoryMenu.swift"] ?? 0, 1,
            "SearchHistoryMenu.swift must spell Divider( exactly once — the menu's separator, drawn by the system's menu machinery"
        )

        let menu = try Self.read(Self.source(named: "SearchHistoryMenu.swift"))
        XCTAssertTrue(
            menu.contains("The one `Divider()` a gated file may spell"),
            "SearchHistoryMenu.swift must name its Divider() as the one a gated file may spell — the comment pins the exception"
        )
    }

    // MARK: - Rule twenty-five: AppKit layer colours are set only inside the drawing appearance

    /// The two panels whose layer colours are set through `performAsCurrentDrawingAppearance`.
    private static let layerColorOwners = [
        "CompletionPanel.swift",
        "HoverPanel.swift",
    ]

    func testAppKitLayerColoursAreSetOnlyInsideTheDrawingAppearance() throws {
        let borderPattern = try NSRegularExpression(pattern: "layer[^\\n]*?\\.\\s*borderColor\\s*=")
        let backgroundPattern = try NSRegularExpression(pattern: "layer[^\\n]*?\\.\\s*backgroundColor\\s*=")
        for name in Self.layerColorOwners {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            let bodies = Self.matchedBodies(after: "performAsCurrentDrawingAppearance", in: code)
            XCTAssertFalse(
                bodies.isEmpty,
                "\(name) has no performAsCurrentDrawingAppearance body — layer colours must be set inside one"
            )
            let combined = bodies.joined(separator: "\n")
            let borderInside = borderPattern.firstMatch(in: combined, range: NSRange(combined.startIndex..., in: combined)) != nil
            let backgroundInside = backgroundPattern.firstMatch(in: combined, range: NSRange(combined.startIndex..., in: combined)) != nil
            XCTAssertTrue(
                borderInside,
                "\(name) has no borderColor assignment inside a performAsCurrentDrawingAppearance body"
            )
            XCTAssertTrue(
                backgroundInside,
                "\(name) has no backgroundColor assignment inside a performAsCurrentDrawingAppearance body"
            )

            var outside = code
            for body in bodies {
                outside = outside.replacingOccurrences(of: body, with: "")
            }
            XCTAssertNil(
                borderPattern.firstMatch(in: outside, range: NSRange(outside.startIndex..., in: outside)),
                "\(name) sets borderColor outside a performAsCurrentDrawingAppearance body — a CGColor is resolved once at assignment"
            )
            XCTAssertNil(
                backgroundPattern.firstMatch(in: outside, range: NSRange(outside.startIndex..., in: outside)),
                "\(name) sets backgroundColor outside a performAsCurrentDrawingAppearance body — a CGColor is resolved once at assignment"
            )

            for body in bodies {
                let borderInBody = borderPattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
                if borderInBody {
                    XCTAssertTrue(
                        LSPSourceGatingTests.containsToken("hairline", in: body),
                        "\(name)'s performAsCurrentDrawingAppearance body sets borderColor but does not name hairline"
                    )
                }
                let backgroundInBody = backgroundPattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
                if backgroundInBody {
                    XCTAssertTrue(
                        LSPSourceGatingTests.containsToken("bgPopover", in: body),
                        "\(name)'s performAsCurrentDrawingAppearance body sets backgroundColor but does not name bgPopover"
                    )
                }
            }
        }
    }

    // MARK: - Rule twenty-six: one field shape

    /// The files that construct the shared field or its box.
    private static let sharedFieldConstructors: Set<String> = [
        "LogFilterBar.swift",
        "SearchBarView.swift",
        "ProjectSearchView.swift",
        "BranchSwitcherView.swift",
        "ChromeControls.swift",
    ]

    /// The files that construct the shared query-mode toggle.
    private static let sharedToggleConstructors: Set<String> = [
        "SearchBarView.swift",
        "ProjectSearchView.swift",
    ]

    func testOneFieldShape() throws {
        let roundedBorderPattern = try NSRegularExpression(pattern: "\\.textFieldStyle\\s*\\(\\s*\\.roundedBorder")
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(
                roundedBorderPattern.firstMatch(in: code, range: range),
                "\(url.lastPathComponent) spells .textFieldStyle(.roundedBorder — a gated file must use the shared field shape"
            )
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("RoundedBorderTextFieldStyle", in: code),
                "\(url.lastPathComponent) spells RoundedBorderTextFieldStyle — a gated file must use the shared field shape"
            )
        }

        var constructors: Set<String> = []
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains("ChromeThemedTextField(") || code.contains("ChromeControlBox(") {
                constructors.insert(name)
            }
        }
        XCTAssertEqual(
            constructors, Self.sharedFieldConstructors,
            "the files constructing the shared field or box must be exactly its four callers plus the defining file"
        )

        var toggleConstructors: Set<String> = []
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if code.contains("ChromeQueryToggle(") {
                toggleConstructors.insert(name)
            }
        }
        XCTAssertEqual(
            toggleConstructors, Self.sharedToggleConstructors,
            "the files constructing the shared query toggle must be exactly its two callers"
        )

        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            if name == "ChromeControls.swift" { continue }
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            XCTAssertFalse(
                code.contains("func toggle("),
                "\(name) declares its own toggle builder — the query toggle is ChromeQueryToggle, one shape for both surfaces"
            )
        }
    }

    // MARK: - Self-check

    /// Every gated file draws with roles and must therefore name one — with two
    /// exceptions: `ChromeThemeEnvironment.swift` carries the *appearance* down
    /// the tree and paints nothing, and `CommitGraphView.swift` draws only lanes,
    /// whose colours are `CommitGraphPalette`'s (the fourth exemption) rather
    /// than roles — so each names no role by construction. Both stay gated for
    /// rules one and two, which is what they can break.
    private static let roleNamingExemptions: Set<String> = [
        "ChromeThemeEnvironment.swift",
        "CommitGraphView.swift",
    ]

    func testEveryGatedFileActuallyNamesARole() throws {
        for url in try Self.swiftSources()
        where Self.gatedFiles.contains(url.lastPathComponent)
            && !Self.roleNamingExemptions.contains(url.lastPathComponent) {
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
        let markers = try NSRegularExpression(pattern: "(?m)^\\s*// MARK: - Rule [a-z-]+:")
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
        13: "thirteen", 14: "fourteen", 15: "fifteen", 16: "sixteen", 17: "seventeen",
        18: "eighteen", 19: "nineteen", 20: "twenty", 21: "twenty-one",
        22: "twenty-two", 23: "twenty-three", 24: "twenty-four",
        25: "twenty-five", 26: "twenty-six",
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
