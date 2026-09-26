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
///   one-point overlap no compiler or headless test can see. And the rule is
///   applied *before* the strip's own opaque ground, since each later
///   `.background` is drawn further back: a rule that exists, is drawn with the
///   right modifier, and is invisible.
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
/// - **No gated file spells `Divider()`; a menu separates with `Section`.** No
///   gated file spells `Divider(`, and every gated file that builds a `Menu`
///   spells `Section` at least once. One stated exception, pinned by set
///   equality: `LeetCodeCommands`' body — a main menu built inside a
///   `Commands` builder, where a `Section` emits a separator on each side of its
///   group — spells exactly one `Divider()` and no `Section`.
/// - **AppKit layer colours are set only inside the drawing appearance.** Every
///   `borderColor` and `backgroundColor` assignment in the two popover panels
///   lies inside a `performAsCurrentDrawingAppearance` body, naming `hairline` and
///   `bgPopover` respectively.
/// - **One field shape.** No gated file spells the rounded-border style; the
///   shared field/box is constructed in exactly eleven callers plus the defining
///   file, and the shared query toggle in exactly two.
/// - **Each measurement follows its own zone.** The Find in Files match row
///   carries no fixed height and is sized by the code font, each popover's
///   corner radius is scaled with the interface metrics, and every `.frame(` in
///   the commit dialog's `messageBox` names `messageLineHeight` and never the
///   interface metrics — the box is counted in lines of the code font it draws at.
/// - **A secondary window's ground is set in the window subclass.** The six
///   controllers constructing `EscClosableWindow` set no `backgroundColor`; the
///   subclass's designated initializer sets `bgPanel`. Two setters compete
///   silently, the later one winning with nothing to say so.
/// - **The merge wash is Core's one answer.** `mergeWashRole(for:)` is read by
///   the merge panes alone, `conflictBackground`/`currentLine`/`bracketMatch` by
///   no app file but the palette, and no gated file chains an alpha onto a
///   role's colour — a composed alpha is a second wash nothing re-themes.
/// - **One primary button, one secondary, one checkbox.** No gated file spells a
///   platform toggle or button style; the shared controls' callers are pinned;
///   every button in part five (b)'s and part five (c)'s files is styled, by a
///   per-file count of constructions against `.buttonStyle(`. A platform control
///   compiles and looks plausible in whichever appearance the reviewer is in.
/// - **A code pane's ground goes through one definition.** `CodePaneGround` has
///   four callers, and no view's `backgroundColor` is set outside its body but
///   at five sites pinned by file and count, each with its reason; no
///   gated file draws an `NSBox`; the architecture documents name the same four
///   callers and never the deleted helper. A second ground drifts from the gutter's.
/// - **A window root resolves the theme the root way.** A root's struct never
///   reads `\.chromeTheme` — its environment is its parent's, the resting
///   appearance — and resolves through a private `chromeColor(_:)`.
/// - **The commit dialog's rows and controls.** The file row states no fixed
///   height and draws the three row states; the checkbox speaks its value; the
///   merge strip's chevrons are named.
/// - **Every chrome glyph is sized in the interface zone.** A symbol with no
///   font of its own draws at the system default, which follows neither zoom;
///   each glyph carries a scaled font of its own, or a scaled frame beside
///   `.resizable()` (a frame alone does not size a symbol that is not resizable),
///   or sits in a pinned declaration whose container font, button style or stated
///   off-scale reason is re-checked.
/// - **A selectable list yields its selected row's background.** On macOS a row
///   background is drawn over the platform's selection box, so every
///   `listRowBackground` under a `List` binding `selection:` is pinned, per
///   file and per list, by set equality; the rule does not read the
///   conditional, so any changed expression fails and a person re-confirms it.
/// - **No gated file builds a platform form control.** A `Form`, `Picker`,
///   `Stepper`, `Toggle` or `TabView` draws in the platform's colours and
///   metrics; the chrome draws a replacement for every one.
/// - **A picker's shape follows its set, and each settings shape has its pinned callers.**
///   A small build-time set is segmented, a run-time set a menu field, a
///   preference a switch; the callers of each shape are pinned by set, and
///   each caller's construction count by file, so a control changing shape
///   changes a count even inside a file already spelling both shapes. The
///   menu field's chevron lies inside its `Menu`'s label, so the arrow it
///   draws is the control. `menuFieldHeight` frames menu fields alone, its
///   spellings pinned per file by count.
/// - **No gated file builds a platform table.** A `Table` draws its header,
///   grounds, alternation and selection box in the platform's colours; no gated
///   file spells `Table` or `TableColumn`, and the browser lays its own rows out.
/// - **The problem catalog's three colour mappings are Core's one answer each.**
///   Difficulty, status and verdict each have one Core role answer and one known
///   reader; no gated file keeps an `isGood` flag, and the case labels left in a
///   view are pinned by count.
/// - **One spinner.** No gated file spells `ProgressView`; `ChromeSpinner`'s
///   callers are pinned by set, and each caller's labelled/hidden pair by file,
///   the twenty sites summed.
/// - **No alternating row fill.** A gated table reads by selection and hover; no
///   gated file spells `alternatingRowBackgrounds`, `isMultiple` or `isTinted`,
///   and no `.background`/`.listRowBackground` modifier's own text spells `% 2`.
///
/// What a rule here may do, and nothing more: pin a set by equality, assert the
/// presence or absence of a token through `containsToken`, or take a
/// brace-matched body and do one of those inside it. A rule does not resolve
/// types, evaluate conditionals or decide which of two branches runs — the three
/// that tried (thirty-one, thirty-four, thirty-five) each missed the regression
/// it named across three review rounds, while no set or token rule failed.
/// Thirty-one is now a total ban with its sites pinned by file and count, and
/// thirty-five a pinned set of row-background expressions that reads no
/// conditional; thirty-four is the one rule still reading a modifier chain,
/// narrowed rather than extended. Thirty-four is the third shape — a balanced
/// region per link, then a token assertion inside it — which is why no rule is
/// excepted from the three. No fourth shape, no exception. A property
/// this cannot express belongs in the app-layer bundle or the acceptance
/// review, not here (`core-theme.md`, beside the rules).
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
        // Part five (b): the secondary windows' one ground, set in the subclass.
        "EscClosableWindow.swift",
        "DiffWindowController.swift",
        "MergeWindowController.swift",
        "SourceViewerWindowController.swift",
        "LocalHistoryWindowController.swift",
        // Part five (b): the two code-hosting window roots whose panes take the
        // shared code-pane ground.
        "SourceViewerContent.swift",
        "DiffWindowContent.swift",
        // Part five (b): the commit dialog, its file row and its author sheet.
        "CommitDialogView.swift",
        // Part five (b): the merge editor — its status strip, pane header and
        // the AppKit panes' wash through `mergeWashRole(for:)`.
        "MergeView.swift",
        // Part five (b): the Local History window — its revisions list, the
        // row and the Restore footer.
        "LocalHistoryView.swift",
        // Part five (c): the Preferences host, General and the catalog tab.
        "SettingsView.swift",
        // Part five (c): the Language Servers page and the installed licences
        // it reads (the latter paints nothing — see `roleNamingExemptions`).
        "LSPServerSettingsView.swift",
        "LSPInstalledLicenses.swift",
        // Part five (c): Acknowledgements and the licence pane behind it. The
        // pane's iOS half is not swept (see `pinnedBackgroundAssignments`).
        "AcknowledgementsView.swift",
        "LicenseTextView.swift",
        // Part five (c): the create and merge pull-request sheets.
        "NewPullRequestSheet.swift",
        "PullRequestMergeSheet.swift",
        // Part five (d): the database viewer tab — its sidebar, grid, footer
        // and error banner.
        "DatabaseViewerView.swift",
        // The viewer's SQL console: its toolbar, input, result table and
        // status bar.
        "DatabaseConsoleView.swift",
        // The problem-catalog browser window: its filter bar, rows and footer.
        "LeetCodeBrowserView.swift",
        // The statement pane beside the editor: its header, collapsed strip,
        // rules and resize handle (the served page itself stays unthemed).
        "LeetCodeDescriptionView.swift",
        // The judge section under the statement.
        "LeetCodeJudgeView.swift",
        // The open-problem sheet and, in the same file, the menu-bar items.
        "LeetCodeOpenProblemSheet.swift",
        // The sign-in sheet's header and footer around the site's own page.
        "LeetCodeLoginView.swift",
        // Part five (e): the text prompt's reason line, an alert accessory
        // coloured through the palette's dynamic AppKit path.
        "FilePanels.swift",
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

    // MARK: - Rule one: no gated view names a system semantic colour

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

    // MARK: - Rule two: no gated view spells a hex literal

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

    // MARK: - Rule three: the four exemptions stay exemptions

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

    // MARK: - Rule four: the theme is injected wherever the interface scale is

    func testTheThemeIsInjectedAtTheInterfaceScaleRoots() throws {
        var found: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if Self.spellsCall(".chromeThemed(", in: code) { found.insert(url.lastPathComponent) }
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

    // MARK: - Rule five: no view constructs a theme inline

    func testOnlyThePlumbingConstructsATheme() throws {
        var constructors: Set<String> = []
        var namers: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if Self.spellsCall("ChromeTheme(", in: code) { constructors.insert(url.lastPathComponent) }
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

    // MARK: - Rule six: the gutter's fill still goes through its own rule

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
            Self.callCount("backgroundRect(", in: code), 2,
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
        matchedBodyRange(after: declaration, in: code).map { String(code[$0]) }
    }

    /// `matchedBody(after:in:)` as a range of `code`, for a rule that must walk
    /// outward from a position inside the body into the file around it.
    static func matchedBodyRange(after declaration: String, in code: String) -> Range<String.Index>? {
        guard let start = code.range(of: declaration) else { return nil }
        guard let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return code.index(after: open)..<index }
            }
            index = code.index(after: index)
        }
        return nil
    }

    // MARK: - Rule seven: no gated view derives a geometry value by arithmetic on a token

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
            if Self.spellsCall("file.url ?? URL(fileURLWithPath: file.displayName)", in: code) {
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
        // Eight, and named: the tree's rows, the inline draft field drawing the
        // placeholder icon a real row would have, the shared tab icon both
        // orientations now ask, and — since part four (a) — the Problems and
        // Usages panels' file-group headers, each of whose exempted line is a
        // `let icon = FileIcon(…)` binding read for its symbol alone (the glyph
        // is drawn in `textSecondary`, a role, on a line rule one still scans).
        // Part four (b) adds the Log's changed-file row and Local Changes' rows
        // and folder headers, whose exempted lines are the same binding.
        // Part five (b) adds the commit dialog's file row, the eighth, whose
        // exempted line is that binding again (its glyph takes
        // `changedFileRole(for:)`, a role, on a line rule one still scans).
        // A ninth is a line that has quietly bought itself out of rule one.
        XCTAssertEqual(
            iconNamers,
            [
                "ProjectTreeDraftField.swift", "ProjectTreeView.swift", "TabStripView.swift",
                "ProblemsPanelView.swift", "UsagesPanelView.swift",
                "CommitLogView.swift", "LocalChangesView.swift",
                "CommitDialogView.swift",
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
            let sites = Self.callCount("MainWindowChrome(", in: code)
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

    // MARK: - Rule ten: every bottom-bar toggle is identifiable without sight

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
    /// Asserted by counting, through this suite's one call matcher `callCount(_:in:)`:
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
                    Self.spellsCall(required, in: body),
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
            Self.callCount("bottomBarButton(", in: code), 2,
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
        XCTAssertTrue(Self.spellsCall("bottomBarButton(", in: toggles), "panelToggles must call bottomBarButton(")
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
            let symbols = Self.callCount("Image(systemName:", in: code)
            XCTAssertGreaterThan(
                symbols, 0,
                "\(name) draws no SF Symbol any more — re-point this rule rather than losing it"
            )
            XCTAssertEqual(
                Self.callCount(".accessibilityHidden(true)", in: code), symbols,
                """
                \(name) must hide every Image(systemName:) it draws — a button combines its \
                children, so an unhidden symbol folds its own name into the button's
                """
            )
            XCTAssertTrue(
                Self.spellsCall(".accessibilityValue(", in: code),
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
            Self.spellsCall(".accessibilityLabel(", in: labelled),
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
    ///
    /// Part five (b) moved the date bound's label into the shared checkbox's
    /// trailing title, so the filter bar's entry is re-pointed at
    /// `ChromeCheckbox`, the one place that label is now drawn.
    private static let headerBuilderFiles: [(file: String, builders: [String])] = [
        ("ProblemsPanelView.swift", ["private var header: some View", "private func severityBadge("]),
        ("UsagesPanelView.swift", ["private var header: some View"]),
        ("TerminalPanelView.swift", ["private func tab(for session:"]),
        ("CommitLogView.swift", ["private var header: some View", "private func label(_ text: String)"]),
        ("ChromeControls.swift", ["struct ChromeCheckbox"]),
        ("LocalChangesView.swift", ["private var toolbar: some View"]),
        ("PullRequestsPanelView.swift", ["private var header: some View", "private var summaryLine: some View"]),
    ]

    func testEveryBottomBarLabelIsSingleLine() throws {
        for name in Self.barLabelFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            XCTAssertTrue(
                Self.spellsCall(".lineLimit(1)", in: code),
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
                let labels = Self.callCount("Text(", in: body)
                XCTAssertGreaterThan(
                    labels, 0,
                    "\(name)'s \(builder) draws no Text any more — re-point this rule rather than losing it"
                )
                XCTAssertEqual(
                    Self.callCount(".lineLimit(1)", in: body), labels,
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
            Self.callCount("DockTabRow(", in: root), 1,
            "\(Self.windowRootFile) must construct the dock's tab row exactly once"
        )
        let slot = try XCTUnwrap(
            Self.matchedBody(after: "func panelContent(", in: root),
            "panelContent( is gone or renamed — re-point this rule rather than losing it"
        )
        XCTAssertTrue(
            Self.spellsCall("DockTabRow(", in: slot),
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
                    Self.spellsCall(modifier, in: body),
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
                Self.spellsCall("Divider(", in: code),
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
            if Self.spellsCall("diagnosticRole(for:", in: code) {
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

    // MARK: - Rule sixteen: an indicator strip's bottom rule is drawn behind its tabs

    /// The strips whose tabs draw an accent indicator on the strip's own bottom
    /// edge: the tab strip above the editor, the dock's tab row and the
    /// Preferences window's tab bar.
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
    /// And the rule must be drawn *in front of* the strip's own ground. SwiftUI
    /// draws each later `.background` further back, so a rule applied after an
    /// opaque `.background(theme.color(.bgPanel))` lands behind that fill and is
    /// never seen — a rule that exists, is drawn with the right modifier, and is
    /// invisible. Part five (c) shipped exactly that on the Preferences tab bar,
    /// whose page below is the same `bgPanel`, so bar and page ran together. So
    /// inside the same body, the first `.background(alignment: .bottom)` naming
    /// `hairline` must come **before** every plain `.background(` whose argument
    /// names a background role (`bgCanvas`, `bgPanel`, `bgEditor`, `bgPopover`) —
    /// two token positions compared inside one matched body, nothing parsed. A
    /// strip that draws no ground on itself satisfies it vacuously: `DockTabRow`
    /// is that case today (its ground belongs to the dock slot around it), which
    /// is why the clause is not unreachable there, only unexercised.
    ///
    /// A named list, rule fourteen's shape: a third strip with a bottom-edge
    /// indicator is added here as part of drawing it, rather than left unguarded.
    /// An entry naming a declaration is read inside that declaration's
    /// brace-matched body alone: the settings tab bar shares its file with every
    /// other shared shape, and another shape's background there must not satisfy
    /// the strip's.
    private static let indicatorStripFiles: [(file: String, declaration: String?)] = [
        ("TabStripView.swift", nil),
        ("DockTabRow.swift", nil),
        ("ChromeControls.swift", "struct ChromeSettingsTabBar"),
    ]

    func testAnIndicatorStripsBottomRuleIsDrawnBehindItsTabs() throws {
        for (file, declaration) in Self.indicatorStripFiles {
            let whole = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: file))
            )
            let name = declaration.map { "\(file)'s \($0)" } ?? file
            let code = try declaration.map {
                try XCTUnwrap(
                    Self.matchedBody(after: $0, in: whole),
                    "\(name) is gone or renamed — re-point this rule rather than losing it"
                )
            } ?? whole
            let overlays = Self.matchedBodies(afterCall: ".overlay(alignment: .bottom)", in: code)
            XCTAssertFalse(
                overlays.contains { LSPSourceGatingTests.containsToken("hairline", in: $0) },
                """
                \(name) overlays its bottom hairline — an overlay paints over the active tab's \
                accent indicator; draw the rule with .background(alignment: .bottom) instead
                """
            )
            let backgrounds = Self.matchedBodies(afterCall: ".background(alignment: .bottom)", in: code)
            XCTAssertTrue(
                backgrounds.contains { LSPSourceGatingTests.containsToken("hairline", in: $0) },
                "\(name) draws no bottom hairline behind its tabs — re-point this rule rather than losing it"
            )
            let rulePosition = Self.callRanges(".background(alignment: .bottom)", in: code)
                .first { range in
                    Self.trailingBody(from: range.upperBound, in: Substring(code))
                        .map { LSPSourceGatingTests.containsToken("hairline", in: $0) } ?? false
                }?.lowerBound
            for ground in Self.groundBackgroundPositions(in: code) {
                XCTAssertTrue(
                    rulePosition.map { $0 < ground } ?? false,
                    """
                    \(name) applies its bottom hairline after an opaque ground — each later .background \
                    is drawn further back, so the rule lands behind the fill and is invisible; apply the \
                    rule first and the ground after, as TabStripView does
                    """
                )
            }
        }
    }

    /// The background roles — the four grounds a strip can fill itself with.
    private static let groundRoles = ["bgCanvas", "bgPanel", "bgEditor", "bgPopover"]

    /// The position of every plain `.background(` in `code` — one whose
    /// argument list does not open with `alignment:` — that names a background
    /// role inside its parenthesised arguments.
    private static func groundBackgroundPositions(in code: String) -> [String.Index] {
        callRanges(".background(", in: code).compactMap { range in
            let open = code.index(before: range.upperBound)
            guard let end = balancedEnd(from: open, in: code) else { return nil }
            let arguments = code[range.upperBound..<code.index(before: end)]
            guard !arguments.drop { $0.isWhitespace }.hasPrefix("alignment") else { return nil }
            let text = String(arguments)
            return groundRoles.contains { LSPSourceGatingTests.containsToken($0, in: text) } ? range.lowerBound : nil
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
            if let body = trailingBody(from: found.upperBound, in: rest) { bodies.append(body) }
            rest = rest[found.upperBound...]
        }
        return bodies
    }

    /// `matchedBodies(after:in:)` for a modifier *call* with its arguments —
    /// `".overlay(alignment: .bottom)"` — found through `callRanges(_:in:)`, so a
    /// wrapped argument list is the same call.
    private static func matchedBodies(afterCall needle: String, in code: String) -> [String] {
        callRanges(needle, in: code).compactMap { trailingBody(from: $0.upperBound, in: Substring(code)) }
    }

    /// The brace-matched block opening at the first `{` after `start` — or `nil`
    /// when anything but whitespace comes first.
    private static func trailingBody(from start: String.Index, in text: Substring) -> String? {
        let gap = text[start...].prefix { $0 != "{" }
        guard gap.allSatisfy(\.isWhitespace), gap.endIndex < text.endIndex else { return nil }
        let block = String(text[gap.endIndex...])
        guard let end = balancedEnd(from: block.startIndex, in: block) else { return nil }
        return String(block[block.index(after: block.startIndex)..<block.index(before: end)])
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
            if Self.spellsCall("changedFileRole(for:", in: code) { readers.insert(name) }
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

    /// The gated files whose case labels share a spelling with a checks state
    /// but name another type's case, each pinned by its exact label count so a
    /// third label — a real checks table — is still red.
    ///
    /// `LSPServerSettingsView.swift`'s two are `case .pending:` in the Go and
    /// Rust rows' status sentences: the toolchain search's first state
    /// (`LSPGoServerRow.status`, `LSPRustServerRow.status`), not a checks state.
    private static let sharedSpellingCaseLabels: [String: Int] = [
        "LSPServerSettingsView.swift": 2,
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
            if Self.spellsCall("checksRole(for:", in: code) { readers.insert(name) }
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
            XCTAssertEqual(
                labels.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)),
                Self.sharedSpellingCaseLabels[url.lastPathComponent, default: 0],
                """
                \(url.lastPathComponent) spells a checks-state case label — a checks mapping in a view is a \
                second table; read the Core glyph, words and ChromeColorRole.checksRole(for:)
                """
            )
        }
    }

    // MARK: - Rule nineteen: the diff wash is Core's one answer, and a diff side is one type

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
            if Self.spellsCall("diffWashRole(for:", in: code) { readers.insert(name) }
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
                    Self.spellsCall(alpha, in: code),
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
    /// An entry with `hidesSymbols: false` is not held to the last clause — the
    /// checks glyph, whose image *is* the element, named and valued outright, and
    /// the shared controls, search rows and problem-browser entries listed with
    /// it. An entry's `forbidden` tokens must be spelled nowhere in its body. A
    /// renamed builder fails loudly rather than narrowing the rule to nothing.
    ///
    /// Each entry's comment claims only what its `required`/`forbidden` tokens
    /// can see: a token is found anywhere in the brace-matched body, with no
    /// argument read beyond what the needle itself spells, no type resolved and
    /// no conditional evaluated — so a claim about an argument is held only when
    /// the needle spells that argument, and a claim about a string literal's
    /// contents is not held at all (the text is literal-stripped).
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
        var forbidden: [String] = []
        /// When set, the body spells `.accessibilityLabel(` exactly this many
        /// times — what an entry saying its controls are *each* named owes, since
        /// `required` is satisfied by one label anywhere in the builder.
        var labelCount: Int?
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
            // Local Changes' revert checkbox, lifted here in part five (b): the
            // label and value it owed moved with it.
            ControlBuilder(path: ["struct ChromeCheckbox"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
            // Part five (c)'s settings shapes and the lifted menu field: each owes
            // its accessibility inside its own body.
            ControlBuilder(path: ["struct ChromeSegmentedControl"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: false),
            ControlBuilder(path: ["struct ChromeStepper"],
                           required: [".accessibilityLabel(", ".accessibilityValue(", ".accessibilityAdjustableAction("],
                           hidesSymbols: false),
            ControlBuilder(path: ["struct ChromeStepper", "private func stepButton("],
                           required: [".accessibilityLabel("], hidesSymbols: true),
            ControlBuilder(path: ["struct ChromeSwitch"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: false),
            ControlBuilder(path: ["struct ChromeSettingsTabBar"],
                           required: [".accessibilityValue("], hidesSymbols: false),
            ControlBuilder(path: ["struct ChromeMenuField"],
                           required: [".accessibilityLabel(", ".accessibilityValue("], hidesSymbols: true),
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
        // Part five (d): the grid footer's two paging chevrons, icon-only, each
        // named outright over a glyph hidden where it is drawn. "Each" is a
        // count: the footer spells exactly three labels — the two chevrons' and
        // its spinner's — so deleting either chevron's is red (fix round 02).
        ("DatabaseViewerView.swift", [
            ControlBuilder(path: ["private var footer: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: true, labelCount: 3),
            ControlBuilder(path: ["private func pagingGlyph("],
                           required: [".accessibilityHidden(true)"], hidesSymbols: true),
        ]),
        // The problem browser's row: one combined element
        // (`.accessibilityElement(children: .combine)`, spelled whole) carrying
        // the selected trait (`.accessibilityAddTraits(isSelected ? .isSelected`,
        // spelled through the trait, so an emptied set is red) and a *named*
        // action (`.accessibilityAction(named:` — the name itself is a string
        // literal this stripped text cannot read, so which name is not held),
        // its Premium lock spoken by a label and hidden nowhere in the body (no
        // `.accessibilityHidden(` at all) — the row's words are the element's.
        // Before fix round 02 the entry spelled only the modifiers' names, so
        // deleting the combining call or emptying the trait stayed green, and
        // an unnamed `.accessibilityAction {` was red only because it has no
        // parenthesis for the matcher to find. The row
        // offers Open in a context menu of its own, and so does the list's
        // container, for the area below the last row where no row is: the
        // platform table this list replaced answered a right-click there with
        // Open for the selection and cleared the selection on a click, and a
        // menu only on the rows silently lost both. Whether that menu *appears*
        // is not something a token rule can see; the container spelling one is.
        ("LeetCodeBrowserView.swift", [
            ControlBuilder(path: ["private struct LeetCodeBrowserRow", "var body: some View"],
                           required: [
                               ".accessibilityElement(children: .combine)",
                               ".accessibilityAddTraits(isSelected ? .isSelected",
                               ".accessibilityAction(named:", ".accessibilityLabel(",
                               ".contextMenu {",
                           ],
                           hidesSymbols: false,
                           forbidden: [".accessibilityHidden("]),
            ControlBuilder(path: ["private var problemList: some View"],
                           required: [".contextMenu {", ".onTapGesture {"], hidesSymbols: false),
        ]),
        // The statement pane's three icon-only buttons — hide and open on the
        // site in the header, show in the collapsed strip — each named outright
        // over a glyph hidden where it is drawn. "Each" is a count: the header
        // spells exactly two labels and the strip exactly one, so deleting any
        // one of the three is red (fix round 02).
        ("LeetCodeDescriptionView.swift", [
            ControlBuilder(path: ["private func header("],
                           required: [".accessibilityLabel("], hidesSymbols: true, labelCount: 2),
            ControlBuilder(path: ["private var collapsedStrip: some View"],
                           required: [".accessibilityLabel("], hidesSymbols: true, labelCount: 1),
            ControlBuilder(path: ["private func iconGlyph("],
                           required: [".accessibilityHidden(true)"], hidesSymbols: true),
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
                        Self.spellsCall(modifier, in: found),
                        """
                        \(name)'s \(described) must spell \(modifier) — a panel control is named after its \
                        glyph, and a state drawn as a colour or a shape is unspoken, until an explicit label \
                        and value replace them (and a menu or click the entry's comment names is lost until it is \
                        spelled again)
                        """
                    )
                }
                if let expected = builder.labelCount {
                    XCTAssertEqual(
                        Self.callRanges(".accessibilityLabel(", in: found).count, expected,
                        """
                        \(name)'s \(described) must spell .accessibilityLabel( exactly \(expected) time(s) — \
                        the entry's comment says each control is named, and one label satisfies `required`
                        """
                    )
                }
                for modifier in builder.forbidden {
                    XCTAssertFalse(
                        Self.spellsCall(modifier, in: found),
                        """
                        \(name)'s \(described) must not spell \(modifier) — the entry's comment says what it \
                        speaks, and a hidden element speaks nothing
                        """
                    )
                }
                guard builder.hidesSymbols else { continue }
                for symbol in Self.callRanges("Image(systemName:", in: found) {
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

    /// Rule twenty's clause for `ChromeSpinner`, checked at its constructions
    /// rather than in its body: the spinner speaks either its activity or
    /// nothing, and which is the call site's to say. Every `ChromeSpinner(` call's
    /// own modifier chain — the postfix links after the call, read from stripped
    /// text, nothing parsed — spells exactly one of `.accessibilityLabel(` (it
    /// stands alone and names what is happening) or `.accessibilityHidden(true)` (a
    /// neighbour already names it, so VoiceOver reads that sentence once rather
    /// than followed by a second, vaguer one). Never neither — an unnamed element
    /// — and never both.
    ///
    /// The two shapes followed are part five (c)'s: `SettingsView.swift`'s label
    /// column hidden where its control speaks for itself, and
    /// `ChromeControls.swift`'s hidden decorative glyphs. The type carries no
    /// label parameter and no default label because a default would be exactly
    /// the duplicate the hidden marker avoids — so the marker is the call site's,
    /// and this clause is where it is owed.
    ///
    /// `spinnerClassification` pins each file's split, confirmed against the tree
    /// site by site; rule forty reads it, by set equality over the files that
    /// construct a spinner: moving a site from one marker to the other, or adding
    /// one, changes a count and a person decides whether the new site's
    /// neighbour names the activity.
    static let spinnerClassification: [String: (labelled: Int, hidden: Int)] = [
        // The header's and the load-more row's: "History" and the row's place
        // say nothing about loading, and "Loading…" is the empty list's alone.
        "CommitLogView.swift": (labelled: 2, hidden: 0),
        // Alone in the dialog's loading state.
        "CommitDialogView.swift": (labelled: 1, hidden: 0),
        // Beside the query toggles; "Searching…" is the empty list's alone.
        "ProjectSearchView.swift": (labelled: 1, hidden: 0),
        // The header's is beside the title; the wait's elapsed time carries
        // what is being waited for, and "Reading checks…" names its own.
        "PullRequestsPanelView.swift": (labelled: 1, hidden: 2),
        // The write's, alone beside the buttons.
        "NewPullRequestSheet.swift": (labelled: 1, hidden: 0),
        // "Reading this repository's merge settings…" names the first; the
        // write's is alone beside the buttons.
        "PullRequestMergeSheet.swift": (labelled: 1, hidden: 1),
        // Each row's status reads "Installing…" or "Removing…" beside it.
        "LSPServerSettingsView.swift": (labelled: 0, hidden: 3),
        // Alone in the footer beside Restore.
        "LocalHistoryView.swift": (labelled: 1, hidden: 0),
        // In the header; "Searching…" is the empty list's alone.
        "UsagesPanelView.swift": (labelled: 1, hidden: 0),
        // The grid footer's: once a page is on screen the text beside it is
        // the row range, which names no load; "Loading…" is the empty page's.
        "DatabaseViewerView.swift": (labelled: 1, hidden: 0),
        // The console toolbar's: beside it stand the pane's "SQL" caption and
        // the Run control, neither of which names the run in progress.
        "DatabaseConsoleView.swift": (labelled: 1, hidden: 0),
        // The browser footer's: it turns for a load or an open, and neither is
        // named beside it — "Loading…" is the empty list's count line alone,
        // and a loaded list's count line names no activity.
        "LeetCodeBrowserView.swift": (labelled: 1, hidden: 0),
        // The judge's: "Running…" or "Submitting…" stands beside it.
        "LeetCodeJudgeView.swift": (labelled: 0, hidden: 1),
        // The open-problem sheet's: "Fetching from LeetCode…" stands beside it.
        "LeetCodeOpenProblemSheet.swift": (labelled: 0, hidden: 1),
    ]

    func testEverySpinnerConstructionSpeaksItsActivityOrNothing() throws {
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let markers = try XCTUnwrap(
                Self.spinnerMarkers(in: code),
                "\(name) constructs a ChromeSpinner whose call does not close"
            )
            for marker in markers {
                XCTAssertTrue(
                    marker.labelled != marker.hidden,
                    """
                    \(name) constructs a ChromeSpinner whose own modifier chain spells \
                    \(marker.labelled ? "both" : "neither") of .accessibilityLabel( and .accessibilityHidden(true) — \
                    the call site says exactly once whether the spinner names its activity or a \
                    neighbour already does
                    """
                )
            }
        }
    }

    /// Rule twenty's clause for `ChromeSpinner`'s own body: whether it turns is
    /// a function of Reduce Motion **as it is now**, never of a value latched
    /// once. The regression this names is the spinner's first shape — a
    /// `@State` flag set in `onAppear` and fed to a value-scoped `.animation`,
    /// so a spinner that appeared under Reduce Motion stayed still for its whole
    /// life after the setting was switched off (the flag never changed again, so
    /// the animation never fired). Read inside the type's brace-matched
    /// declaration, stripped: `onAppear` and `@State` are absent, and the
    /// reduce-motion property is named inside the argument list of the
    /// `TimelineView(` that drives the turn — as its `paused:` value — so a
    /// change in either direction reaches the schedule. Presence and absence
    /// only; which branch runs is not read.
    func testSpinnerTurnsOnReduceMotionAsItIsNow() throws {
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "ChromeControls.swift"))
        )
        let body = try XCTUnwrap(
            Self.matchedBody(after: "struct ChromeSpinner", in: code),
            "ChromeControls.swift declares no ChromeSpinner"
        )
        for latch in ["onAppear", "State"] {
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken(latch, in: body),
                "ChromeSpinner spells \(latch) — a latched flag cannot follow Reduce Motion switched off under it"
            )
        }
        let drivers = Self.matchedArguments(after: "TimelineView", in: body)
        XCTAssertEqual(drivers.count, 1, "ChromeSpinner's turn is driven by exactly one TimelineView")
        XCTAssertTrue(
            drivers.allSatisfy {
                $0.range(of: #"paused\s*:\s*reduceMotion(?![A-Za-z0-9_])"#, options: .regularExpression) != nil
            },
            "ChromeSpinner's TimelineView must pause on the reduce-motion property itself"
        )
    }

    /// Each `ChromeSpinner(` construction in `code`, in order, with which of the
    /// two accessibility markers its own modifier chain spells; `nil` when a
    /// call does not close. Read by rule twenty's clause (exactly one marker per
    /// construction) and rule forty (the per-file pair).
    ///
    /// The hidden marker is `.accessibilityHidden(true)` exactly, the literal the
    /// contract names — `isHiddenByItsOwnChain(imageAt:in:)`'s own match — never
    /// the call prefix: `.accessibilityHidden(false)` leaves an unnamed element,
    /// and `.accessibilityHidden(someFlag)` leaves one whenever the flag is false,
    /// so both count as no marker and fail the clause as "neither". The stripped
    /// text keeps `true`, which is not a string literal. Shown red against both
    /// mutations at `LeetCodeJudgeView.swift`'s spinner before it was committed;
    /// the prefix match it replaces stayed green on each.
    static func spinnerMarkers(in code: String) -> [(labelled: Bool, hidden: Bool)]? {
        var markers: [(labelled: Bool, hidden: Bool)] = []
        for call in callRanges("ChromeSpinner(", in: code) {
            let open = code.index(before: call.upperBound)
            guard let end = balancedEnd(from: open, in: code) else { return nil }
            let chain = String(modifierChain(from: end, in: code))
            markers.append((
                labelled: spellsCall(".accessibilityLabel(", in: chain),
                hidden: spellsCall(".accessibilityHidden(true)", in: chain)
            ))
        }
        return markers
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
        if spellsCall(hidden, in: String(modifierChain(from: callEnd, in: code))) { return true }
        var depth = 0
        var index = image
        while index > code.startIndex {
            index = code.index(before: index)
            if code[index] == "}" { depth += 1 }
            if code[index] == "{" {
                if depth > 0 { depth -= 1; continue }
                guard let blockEnd = balancedEnd(from: index, in: code) else { return false }
                if spellsCall(hidden, in: String(modifierChain(from: blockEnd, in: code))) { return true }
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

    // MARK: - Rule twenty-one: the Log's filter bar states no fixed width and scrolls below its floor

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
            Self.spellsCall("ScrollView(.horizontal", in: code),
            """
            LogFilterBar.swift draws its row in no horizontal ScrollView — below the floor its \
            minimums compose, the row must scroll rather than clip
            """
        )
    }

    // MARK: - Rule twenty-two: a pushed resize cursor is released when its view disappears

    /// The functions, per gated file, that push an `NSCursor` — pinned by
    /// equality so a scanner that stopped finding them fails instead of passing
    /// vacuously, and a new hand-rolled divider joins the rule deliberately.
    static let cursorPushingFunctions: Set<String> = [
        "CommitLogView.swift: syncDivideCursor",
        "ContentView.swift: syncPanelDividerCursor",
        "ContentView.swift: syncMarkdownDividerCursor",
        "LeetCodeDescriptionView.swift: syncResizeHandleCursor",
    ]

    /// A hand-rolled divider pushes the resize cursor from hover and drag state
    /// and pops it from `onHover(false)` or the drag's `onEnded`. Neither arrives
    /// when the divider leaves the tree with the pointer on it or mid-drag — the
    /// Log's list/detail divide exists only while a commit is selected, the model
    /// clears the selection on its refresh paths, and a dock tab switch takes the
    /// whole panel away — and `NSCursor`'s stack is global, so the cursor stays
    /// pushed after the flag that would have balanced it is gone. The defect
    /// shipped once, in the Log's divide; the two `ContentView` dividers already
    /// released from `onDisappear`, which is the rule this states for all four
    /// (the statement pane's resize handle joined in part five (d)).
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
                      body.contains("NSCursor"), Self.spellsCall(".push()", in: body) else { continue }
                found.insert("\(file): \(name)")
                pushesInFunctions += Self.callCount(".push()", in: body)
                XCTAssertTrue(
                    disappearances.contains { Self.spellsCall("\(name)(", in: $0) },
                    """
                    \(file): \(name) pushes an NSCursor but no .onDisappear { block calls it — a view \
                    leaving the tree with the pointer on it, or mid-drag, gets neither onHover(false) nor \
                    onEnded, and the cursor stays pushed after its flag is gone
                    """
                )
            }
            XCTAssertEqual(
                Self.callCount(".push()", in: code), pushesInFunctions,
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
            let presentsPopover = Self.spellsCall(".popover(", in: code) || LSPSourceGatingTests.containsToken("NSPanel", in: code)
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

    // MARK: - Rule twenty-four: no gated file spells Divider(); a menu separates with Section

    /// The gated files that build a `Menu` and separate with `Section` — the
    /// menu's separator is a `Section` boundary in this repository, and
    /// `Divider()` is the platform's separator colour at the system's thickness,
    /// a step off the `hairline` role.
    ///
    /// `DatabaseViewerView.swift` is here by the rule's own reading rather than
    /// by a separator: its cell menu (Copy, Set to NULL) has two items and none,
    /// and the `Section` it spells is the sidebar list's (Tables, Views). The
    /// computed set pairs any `Section` with any menu in the same file, so the
    /// file lands in both sets and is pinned in both, deliberately.
    private static let menuSectionFiles: Set<String> = [
        "SearchHistoryMenu.swift",
        "ProjectTreeView.swift",
        "LocalChangesView.swift",
        "DatabaseViewerView.swift",
    ]

    /// Every gated file that builds a `Menu` (whether or not it separates).
    /// `menuSectionFiles` is the subset that must also spell `Section`; the
    /// two pinned sets together make a fourth `Menu` without `Section` visible
    /// — the previous `hasSection && hasMenu` equality could not see it, as
    /// `BranchSwitcherView.swift` and `LogFilterBar.swift` already demonstrated.
    ///
    /// `LogFilterBar.swift` left the set in part five (c): its branch menu is now
    /// the shared `ChromeMenuField`, so the one `Menu` it drew lives in
    /// `ChromeControls.swift`, which joined in its place.
    private static let menuFiles: Set<String> = [
        "BranchSwitcherView.swift",
        "ChromeControls.swift",
        "SearchHistoryMenu.swift",
        "ProjectTreeView.swift",
        "LocalChangesView.swift",
        "DatabaseViewerView.swift",
        "LeetCodeBrowserView.swift",
    ]

    /// The one exception to "no gated file spells `Divider()`": a main menu's
    /// items built inside a `Commands`/`CommandMenu` builder, keyed by file to
    /// the declaration whose body holds them.
    ///
    /// There the rule's premise — that a `Section` stands in for the platform's
    /// separator — is false. A standalone probe built against the real AppKit
    /// menu (item arrays read after `NSMenu.update()`, heights from `NSMenu.size`)
    /// measured four shapes of the same three items inside a `Commands` builder:
    /// `Section { A; B }; Section { C }` drew four separators at 126 pt (one
    /// above the first item, two adjacent between the groups, one below the
    /// last); `A; B; Section { C }` and `Section { A; B }; C` each drew two at
    /// 104 pt; `A; B; Divider(); C` drew one at 93 pt. AppKit neither hides the
    /// edge separators nor collapses adjacent ones, so only `Divider()` gives one
    /// separator between two groups — and a main menu separator is drawn by
    /// AppKit where no chrome role reaches it anyway.
    ///
    /// Every `Commands`/`CommandMenu` builder in the repository, enumerated when
    /// this was written: `PisakaApp.swift`'s `.commands` (not gated, so it needs
    /// nothing, though it spells `Divider()` five times across three menu
    /// builders), `FoldCommands.swift` (not gated, and spells no separator) and
    /// `LeetCodeCommands`, the body `PisakaApp`'s `CommandMenu("LeetCode")`
    /// hosts — the only one in a gated file, hence the only entry.
    private static let commandsDividerBodies: [String: String] = [
        "LeetCodeOpenProblemSheet.swift": "struct LeetCodeCommands",
    ]

    func testNoGatedFileSpellsDividerAndEveryMenuUsesSection() throws {
        let dividerPattern = try NSRegularExpression(pattern: "\\bDivider\\s*\\(")
        let sectionPattern = try NSRegularExpression(pattern: "\\bSection\\b")
        var actualDividerFiles: Set<String> = []
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            var code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if dividerPattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                actualDividerFiles.insert(name)
            }
            if let declaration = Self.commandsDividerBodies[name] {
                // The exception's shape: the commands body spells exactly one
                // `Divider()` and no `Section` — a silent swap back to the
                // two-`Section` shape, or a second divider, moves this pin.
                let typeBody = try XCTUnwrap(
                    Self.matchedBody(after: declaration, in: code),
                    "\(name) no longer declares \(declaration)"
                )
                let body = try XCTUnwrap(
                    Self.matchedBody(after: "var body: some View", in: typeBody),
                    "\(declaration) no longer has a body"
                )
                let bodyRange = NSRange(body.startIndex..., in: body)
                XCTAssertEqual(
                    dividerPattern.numberOfMatches(in: body, range: bodyRange), 1,
                    "\(declaration)'s menu separates its two groups with exactly one Divider() — the one shape a Commands builder draws as one separator"
                )
                XCTAssertEqual(
                    sectionPattern.numberOfMatches(in: body, range: bodyRange), 0,
                    "\(declaration)'s menu spells Section — inside a Commands builder that draws a separator on each side of the group"
                )
                // Everything outside that one body is held to the ordinary rule.
                let bodyInFile = try XCTUnwrap(Self.matchedBodyRange(after: declaration, in: code))
                code.removeSubrange(bodyInFile)
            }
            let range = NSRange(code.startIndex..., in: code)
            XCTAssertNil(
                dividerPattern.firstMatch(in: code, range: range),
                "\(name) spells Divider( — a gated surface draws its own hairline, a menu separates with Section"
            )
        }
        XCTAssertEqual(
            actualDividerFiles, Set(Self.commandsDividerBodies.keys),
            "the gated files spelling Divider( are exactly the commands-builder exception's"
        )

        for name in Self.menuSectionFiles {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            XCTAssertTrue(
                code.contains("Section"),
                "\(name) builds a Menu and must spell Section at least once — a menu's separator is a Section boundary"
            )
        }

        let menuPattern = try NSRegularExpression(pattern: "\\bMenu\\s*(?:\\(|\\{)")
        let contextMenuPattern = try NSRegularExpression(pattern: "(?:\\.contextMenu|projectTreeContextMenu)")
        var actualMenuFiles: Set<String> = []
        var actualMenuSectionFiles: Set<String> = []
        for url in try Self.swiftSources() where Self.gatedFiles.contains(url.lastPathComponent) {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let range = NSRange(code.startIndex..., in: code)
            let hasSection = code.contains("Section")
            let hasMenu = menuPattern.firstMatch(in: code, range: range) != nil
                || contextMenuPattern.firstMatch(in: code, range: range) != nil
            if hasMenu { actualMenuFiles.insert(url.lastPathComponent) }
            if hasSection && hasMenu { actualMenuSectionFiles.insert(url.lastPathComponent) }
        }
        XCTAssertEqual(
            actualMenuFiles, Self.menuFiles,
            "a gated Menu was added, removed or renamed without updating the pinned set — update menuFiles"
        )
        XCTAssertEqual(
            actualMenuSectionFiles, Self.menuSectionFiles,
            "a menu file lost its Section or a fourth menu was added without updating the pinned set"
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
        "CommitDialogView.swift",
        "NewPullRequestSheet.swift",
        "PullRequestMergeSheet.swift",
        "DatabaseViewerView.swift",
        "LeetCodeBrowserView.swift",
        "LeetCodeJudgeView.swift",
        "LeetCodeOpenProblemSheet.swift",
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
            if Self.spellsCall("ChromeThemedTextField(", in: code) || Self.spellsCall("ChromeControlBox(", in: code) {
                constructors.insert(name)
            }
        }
        XCTAssertEqual(
            constructors, Self.sharedFieldConstructors,
            "the files constructing the shared field or box must be exactly its eleven callers plus the defining file"
        )

        var toggleConstructors: Set<String> = []
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if Self.spellsCall("ChromeQueryToggle(", in: code) {
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

    /// The two query-toggle rows speak the same three names. The shared toggle
    /// speaks its `help` as its accessibility label, so a caller that words one
    /// mode differently ("Words" beside "Whole word") names one control two ways.
    /// Matched against comment-stripped text *with* literals kept, because the
    /// names under test are the literals — the usual scanner would delete them.
    func testQueryTogglesSpeakOneNamePerMode() throws {
        let pattern = try NSRegularExpression(pattern: "ChromeQueryToggle\\([^)]*?help:\\s*\"([^\"]*)\"")
        var names: [String: [String]] = [:]
        for url in try Self.swiftSources() where Self.sharedToggleConstructors.contains(url.lastPathComponent) {
            let code = GitHubSourceGatingTests.strippingComments(try Self.read(url))
            let range = NSRange(code.startIndex..., in: code)
            names[url.lastPathComponent] = pattern.matches(in: code, range: range).compactMap {
                Range($0.range(at: 1), in: code).map { String(code[$0]) }
            }
        }
        XCTAssertEqual(Set(names.keys), Self.sharedToggleConstructors)
        for (name, spoken) in names {
            XCTAssertEqual(
                spoken, ["Match case", "Whole word", "Regular expression"],
                "\(name)'s query toggles must speak the one name each mode has"
            )
        }
    }

    /// Every `ChromeThemedTextField(` construction whose name is *drawn* as the
    /// empty field's placeholder (`title:`), by file and count.
    private static let sharedFieldDrawnNameCallers: [String: Int] = [
        "CommitDialogView.swift": 2,
        "ProjectSearchView.swift": 3,
        "SearchBarView.swift": 2,
        "NewPullRequestSheet.swift": 1,
        "PullRequestMergeSheet.swift": 1,
        "BranchSwitcherView.swift": 1,
        "LogFilterBar.swift": 3,
        "LeetCodeOpenProblemSheet.swift": 1,
        "LeetCodeBrowserView.swift": 1,
    ]

    /// Every `ChromeThemedTextField(` construction whose name is spoken and
    /// **never drawn** (`spokenName:`), by file and count: the database grid's
    /// cell editor alone. An empty cell editor is itself a value — a NULL cell
    /// seeds empty, so does an empty-string cell — and a grey column name in it
    /// reads as a dimmed stored value, grey being how the grid draws NULL. The
    /// field it replaced drew nothing there; part five (d) drew the name and the
    /// fix round moved it back.
    private static let sharedFieldSpokenOnlyCallers: [String: Int] = [
        "DatabaseViewerView.swift": 1,
    ]

    /// Which shared-field callers draw their name and which only speak it, both
    /// pinned by file and count, so moving a caller from one initializer to the
    /// other fails until the pin moves with it. The regression it names: the
    /// grid's cell editor passing `title:`, which puts the column's name in grey
    /// inside an empty field where grey means NULL. Every construction must lead
    /// with one of the two labels — nothing else reaches the field.
    func testSharedFieldDrawsItsNameExceptAtTheCellEditor() throws {
        var drawn: [String: Int] = [:]
        var spokenOnly: [String: Int] = [:]
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            for arguments in Self.matchedArguments(after: "ChromeThemedTextField", in: code) {
                let inside = String(arguments.dropFirst())
                let first = Self.topLevelArguments(inside).first ?? ""
                if first.hasPrefix("title:") {
                    drawn[name, default: 0] += 1
                } else if first.hasPrefix("spokenName:") {
                    spokenOnly[name, default: 0] += 1
                } else {
                    XCTFail("\(name) constructs ChromeThemedTextField leading with neither title: nor spokenName: (\(first))")
                }
            }
        }
        XCTAssertEqual(
            drawn, Self.sharedFieldDrawnNameCallers,
            "the shared field's drawn-name callers (title:) must be exactly the pinned set"
        )
        XCTAssertEqual(
            spokenOnly, Self.sharedFieldSpokenOnlyCallers,
            "the shared field's spoken-only callers (spokenName:) must be exactly the grid's cell editor"
        )

        let controls = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(try Self.source(named: "ChromeControls.swift"))
        )
        let field = try XCTUnwrap(
            Self.matchedBody(after: "struct ChromeThemedTextField", in: controls),
            "ChromeThemedTextField's declaration is gone or renamed — re-point this rule"
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("drawsTitle", in: field),
            "ChromeThemedTextField no longer reads drawsTitle — spokenName: would draw the name after all"
        )
    }

    // MARK: - Rule twenty-seven: each measurement follows its own zone

    /// The Find in Files match row is sized by the code font rather than a fixed
    /// interface-scaled height, and each popover's corner radius is scaled with
    /// the interface metrics. Both are the same mistake in opposite directions —
    /// a chrome measurement that does not follow the interface scale, and a
    /// code-zone measurement that does — and would have been caught by this rule.
    func testEachMeasurementFollowsItsOwnZone() throws {
        let projectSearchCode = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "ProjectSearchView.swift"))
        )
        let rowBody = try XCTUnwrap(
            Self.matchedBody(after: "private func row(", in: projectSearchCode),
            "ProjectSearchView.swift's private func row( is gone or renamed — re-point this rule rather than losing it"
        )
        XCTAssertTrue(
            rowBody.contains("settings.fontSize"),
            "ProjectSearchView.swift's row body must name settings.fontSize — the row draws at the code font"
        )
        let hasFrameHeight = try Self.hasFrameHeight(in: rowBody)
        XCTAssertFalse(
            hasFrameHeight,
            "ProjectSearchView.swift's row body spells .frame(height: — the row carries no fixed height, sized by its code-font content"
        )

        // The commit message box is counted in lines of the code font it draws
        // at: every frame in it names that line height, and none names the
        // interface metrics — a fixed point height followed no zone at all.
        let commitDialogCode = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "CommitDialogView.swift"))
        )
        let messageBoxBody = try XCTUnwrap(
            Self.matchedBody(after: "private var messageBox", in: commitDialogCode),
            "CommitDialogView.swift's private var messageBox is gone or renamed — re-point this rule rather than losing it"
        )
        let messageBoxFrames = Self.callRanges(".frame(", in: messageBoxBody)
        XCTAssertGreaterThan(
            messageBoxFrames.count, 0,
            "CommitDialogView.swift's messageBox applies no .frame( — the box's height must be counted in code-font lines"
        )
        for call in messageBoxFrames {
            let open = messageBoxBody.index(before: call.upperBound)
            let end = try XCTUnwrap(Self.balancedEnd(from: open, in: messageBoxBody))
            let args = String(messageBoxBody[open..<end])
            XCTAssertTrue(
                LSPSourceGatingTests.containsToken("messageLineHeight", in: args),
                "CommitDialogView.swift's messageBox has a .frame( that does not name messageLineHeight — the box follows the code zone"
            )
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("metrics", in: args),
                "CommitDialogView.swift's messageBox has a .frame( that names metrics"
                    + " — the message box's height is the code zone's, not the interface's"
            )
        }

        for name in ["CompletionPanel.swift", "HoverPanel.swift"] {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            let lines = code.components(separatedBy: .newlines)
            let cornerLines = lines.filter { $0.contains("cornerRadius") }
            XCTAssertGreaterThan(
                cornerLines.count, 0,
                "\(name) has no cornerRadius assignment — each popover must have at least one, scaled with the interface"
            )
            for line in cornerLines {
                XCTAssertTrue(
                    line.contains("metrics"),
                    "\(name) has a cornerRadius assignment that does not name metrics on the same statement — the radius must be scaled with the interface"
                )
            }
        }
    }

    /// Whether `body` applies a `.frame(…)` whose own argument list (depth one,
    /// not a nested call's) names `height:` — tolerant of line breaks, because
    /// `.frame(\n    height:` is the same fixed height as `.frame(height:`.
    ///
    /// Rule twenty-seven's walk, factored out when rule thirty-three needed the
    /// same reading of another row: one definition, so the two rules cannot come
    /// to disagree about what "a fixed height" means.
    static func hasFrameHeight(in body: String) throws -> Bool {
        let heightPattern = try NSRegularExpression(pattern: "\\bheight\\s*:")
        for call in callRanges(".frame(", in: body) {
            let idx = body.index(before: call.upperBound)
            guard let end = balancedEnd(from: idx, in: body) else { continue }
            let args = String(body[idx..<end])
            for match in heightPattern.matches(in: args, range: NSRange(args.startIndex..., in: args)) {
                guard let matchRange = Range(match.range, in: args) else { continue }
                var depth = 0
                for character in args[args.startIndex..<matchRange.lowerBound] {
                    if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
                }
                if depth == 1 { return true }
            }
        }
        return false
    }

    /// Occurrences of `identifier` as a whole token — `containsToken`'s boundary
    /// rule, counted rather than answered once.
    static func tokenCount(_ identifier: String, in code: String) -> Int {
        var count = 0
        var rest = Substring(code)
        while let found = rest.range(of: identifier) {
            let before = found.lowerBound > code.startIndex ? code[code.index(before: found.lowerBound)] : " "
            let after = found.upperBound < code.endIndex ? code[found.upperBound] : " "
            func isIdentifier(_ character: Character) -> Bool {
                character.isLetter || character.isNumber || character == "_"
            }
            if !isIdentifier(before) && !isIdentifier(after) { count += 1 }
            rest = code[found.upperBound...]
        }
        return count
    }

    /// The source files of every gated file, stripped.
    private static func strippedGatedSources() throws -> [(name: String, code: String)] {
        try swiftSources()
            .filter { gatedFiles.contains($0.lastPathComponent) }
            .map { ($0.lastPathComponent, LSPSourceGatingTests.strippingCommentsAndStringLiterals(try read($0))) }
    }

    /// Part five (b)'s ten files: the ones rules twenty-nine and thirty hold to
    /// stricter clauses than the rest of the gated set, because they were written
    /// (or rewritten) against those clauses.
    static let partFiveBFiles: Set<String> = [
        "CommitDialogView.swift",
        "MergeView.swift",
        "MergeWindowController.swift",
        "DiffWindowContent.swift",
        "DiffWindowController.swift",
        "SourceViewerContent.swift",
        "SourceViewerWindowController.swift",
        "LocalHistoryView.swift",
        "LocalHistoryWindowController.swift",
        "EscClosableWindow.swift",
    ]

    // MARK: - Rule twenty-eight: a secondary window's ground is set in the window subclass

    /// The six controllers that construct `EscClosableWindow`. A window's ground
    /// is a property of the window, and two setters compete silently — the later
    /// one wins and nothing says so — so the ground lives in the subclass's
    /// designated initializer, which both construction paths go through, and no
    /// controller sets one of its own.
    private static let escClosableWindowConstructors: Set<String> = [
        "DiffWindowController.swift",
        "MergeWindowController.swift",
        "SourceViewerWindowController.swift",
        "LocalHistoryWindowController.swift",
        "ProjectSearchWindowController.swift",
        "LeetCodeBrowserWindowController.swift",
    ]

    func testASecondaryWindowsGroundIsSetInTheWindowSubclass() throws {
        // A construction is a call: the token followed by its argument list.
        // `PisakaApp.swift`'s `is EscClosableWindow` names the type without
        // constructing one, and the subclass's own declaration is followed by a
        // colon — neither is a hit.
        let construction = try NSRegularExpression(pattern: "\\bEscClosableWindow\\s*\\(")
        // A pattern rather than a token: the clause is about an assignment's
        // shape — `backgroundColor =`, not `==` — which the identifier's
        // presence alone cannot tell apart from a read.
        let assignment = try NSRegularExpression(pattern: "\\bbackgroundColor\\s*=(?!=)")
        var constructors: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if construction.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                constructors.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            constructors, Self.escClosableWindowConstructors,
            "the files constructing EscClosableWindow must be exactly the six secondary-window controllers"
        )
        for name in Self.escClosableWindowConstructors.sorted() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            XCTAssertNil(
                assignment.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                "\(name) assigns backgroundColor — a secondary window's ground is EscClosableWindow's, set once in the subclass"
            )
        }

        let window = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "EscClosableWindow.swift"))
        )
        let initBody = try XCTUnwrap(
            Self.matchedBody(after: "override init(", in: window),
            "EscClosableWindow's designated initializer is gone — re-point this rule rather than losing it"
        )
        XCTAssertNotNil(
            assignment.firstMatch(in: initBody, range: NSRange(initBody.startIndex..., in: initBody)),
            "EscClosableWindow's designated initializer must assign backgroundColor — it is the one ground setter"
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("bgPanel", in: initBody),
            "EscClosableWindow's designated initializer must name bgPanel — every secondary window stands on it"
        )
    }

    // MARK: - Rule twenty-nine: the merge wash is Core's one answer

    /// `mergeWashRole(for:)` is read by the merge panes alone; the three roles it
    /// and the code zone's line overlays own are spelled by no app file but the
    /// palette; and no gated file composes an alpha onto a role's colour.
    ///
    /// The alpha clause is a pattern over a call and the member chained onto it
    /// — `nsColor(…)`, `.color(…)` or `chromeColor(…)`, its brace-matched
    /// argument list, then `.withAlphaComponent`/`.opacity`, line breaks allowed
    /// between them. No token can express "chained onto *this* call": the
    /// identifiers are everywhere, and `.opacity(` is a view modifier too.
    /// `MinimapView.swift`'s `withAlphaComponent(0.6)` is outside the rule by
    /// what it applies to — a syntax-table colour, the code zone's, not a role's.
    /// This part's ten files, written against the rule, ban the token outright.
    private static let mergeWashReaders: Set<String> = ["MergeView.swift"]

    func testTheMergeWashIsCoresOneAnswer() throws {
        var readers: Set<String> = []
        for url in try Self.swiftSources() where url.path.contains("/Sources/Pisaka/") {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if LSPSourceGatingTests.containsToken("mergeWashRole", in: code) { readers.insert(name) }
            guard name != "ChromePalette.swift" else { continue }
            for role in ["conflictBackground", "currentLine", "bracketMatch"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(role, in: code),
                    "\(name) names \(role) directly — the merge wash is ChromeColorRole.mergeWashRole(for:)'s answer, the other two are the code zone's"
                )
            }
        }
        XCTAssertEqual(
            readers, Self.mergeWashReaders,
            "the app files reading ChromeColorRole.mergeWashRole(for:) must be exactly the merge panes"
        )

        let roleColor = try NSRegularExpression(pattern: "(?:\\bnsColor|\\.color|\\bchromeColor)\\s*\\(")
        for (name, code) in try Self.strippedGatedSources() {
            for match in roleColor.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range, in: code),
                      let callEnd = Self.balancedEnd(from: code.index(before: range.upperBound), in: code)
                else { continue }
                var index = callEnd
                while index < code.endIndex, code[index].isWhitespace { index = code.index(after: index) }
                guard index < code.endIndex, code[index] == "." else { continue }
                let member = code[code.index(after: index)...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                XCTAssertFalse(
                    member == "withAlphaComponent" || member == "opacity",
                    "\(name) chains .\(member) onto a role's colour — a wash's alpha is the palette's, not one composed at the use site"
                )
            }
            if Self.partFiveBFiles.contains(name) {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken("withAlphaComponent", in: code),
                    "\(name) spells withAlphaComponent — part five (b)'s surfaces compose no alpha of their own"
                )
            }
            if name == "MergeView.swift" {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken("performAsCurrentDrawingAppearance", in: code),
                    """
                    MergeView.swift spells performAsCurrentDrawingAppearance — the wash is a dynamic NSColor \
                    filled at draw time, which resolves at that moment; the bracket is for layer CGColors
                    """
                )
            }
        }
    }

    // MARK: - Rule thirty: one primary button, one secondary, one checkbox

    /// The files spelling each shared control, the defining file included.
    private static let sharedControlCallers: [(token: String, files: Set<String>)] = [
        ("chromePrimary", [
            "ChromeControls.swift", "CommitDialogView.swift", "MergeView.swift",
            "NewPullRequestSheet.swift", "PullRequestMergeSheet.swift", "LeetCodeOpenProblemSheet.swift",
        ]),
        ("chromeSecondary", [
            "ChromeControls.swift", "SearchBarView.swift", "ProjectSearchView.swift",
            "CommitDialogView.swift", "MergeView.swift", "LocalHistoryView.swift",
            "SettingsView.swift", "LSPServerSettingsView.swift",
            "NewPullRequestSheet.swift", "PullRequestMergeSheet.swift",
            "DatabaseConsoleView.swift", "LeetCodeBrowserView.swift",
            "LeetCodeJudgeView.swift", "LeetCodeOpenProblemSheet.swift", "LeetCodeLoginView.swift",
        ]),
        ("ChromeCheckbox", [
            "ChromeControls.swift", "CommitDialogView.swift", "LogFilterBar.swift", "LocalChangesView.swift",
            "NewPullRequestSheet.swift", "LeetCodeBrowserView.swift",
        ]),
    ]

    /// Each of part five (b)'s ten files: how many `Button` constructions it
    /// spells, and — equal, because every one is styled — how many
    /// `.buttonStyle(` applications. Zero is stated, not defaulted, so a first
    /// button in a controller is a deliberate edit here.
    private static let partFiveBButtonCounts: [String: Int] = [
        "CommitDialogView.swift": 5,
        "MergeView.swift": 7,
        "LocalHistoryView.swift": 1,
        "MergeWindowController.swift": 0,
        "DiffWindowContent.swift": 0,
        "DiffWindowController.swift": 0,
        "SourceViewerContent.swift": 0,
        "SourceViewerWindowController.swift": 0,
        "LocalHistoryWindowController.swift": 0,
        "EscClosableWindow.swift": 0,
    ]

    /// Part five (c)'s seven files, held to the same rule on the same terms.
    /// `SettingsView.swift` spells three: the account row builds one of
    /// Sign In… / Sign Out conditionally, but both are spelled, and the catalog
    /// tab's Change… is the third.
    private static let partFiveCButtonCounts: [String: Int] = [
        "SettingsView.swift": 3,
        "LSPServerSettingsView.swift": 6,
        "AcknowledgementsView.swift": 1,
        "NewPullRequestSheet.swift": 2,
        "PullRequestMergeSheet.swift": 2,
        "LSPInstalledLicenses.swift": 0,
        "LicenseTextView.swift": 0,
    ]

    /// Part five (d)'s files, whose buttons are not all styleable: a menu item
    /// and a confirmation dialog's button take no button style. So each file
    /// states two numbers, its `Button` count and its `.buttonStyle(` count,
    /// both confirmed against the tree, and the difference is the unstyleable
    /// buttons named in the entry's comment.
    private static let partFiveDButtonCounts: [String: (buttons: Int, styled: Int)] = [
        // The sort headers, the hidden Return button and the two paging
        // chevrons are styled; the cell menu's Copy and Set to NULL are menu
        // items.
        "DatabaseViewerView.swift": (buttons: 6, styled: 4),
        // Run is styled; the confirmation dialog's Run and Cancel are the
        // platform dialog's buttons and take no style.
        "DatabaseConsoleView.swift": (buttons: 3, styled: 1),
        // Open, Sign In…, Refresh and the hidden Return button are styled; the
        // row's context-menu Open and the list's (below the last row) are menu
        // items.
        "LeetCodeBrowserView.swift": (buttons: 6, styled: 4),
        // The three icon-only buttons are all `.plain`.
        "LeetCodeDescriptionView.swift": (buttons: 3, styled: 3),
        // Run and Submit.
        "LeetCodeJudgeView.swift": (buttons: 2, styled: 2),
        // The sheet's Sign In…, Cancel and Open are styled; `LeetCodeCommands`'
        // five menu-bar items (Open Problem…, Browse Problems…, Sign Out,
        // Sign In… and Choose LeetCode Folder…) are menu items.
        "LeetCodeOpenProblemSheet.swift": (buttons: 8, styled: 3),
        // Cancel.
        "LeetCodeLoginView.swift": (buttons: 1, styled: 1),
    ]

    func testOnePrimaryButtonOneSecondaryOneCheckbox() throws {
        XCTAssertEqual(Set(Self.partFiveBButtonCounts.keys), Self.partFiveBFiles)
        XCTAssertTrue(
            Set(Self.partFiveCButtonCounts.keys).isSubset(of: Self.gatedFiles),
            "a part five (c) button count names a file that is not gated"
        )
        XCTAssertTrue(
            Set(Self.partFiveDButtonCounts.keys).isSubset(of: Self.gatedFiles),
            "a part five (d) button count names a file that is not gated"
        )
        // A declaration named like the checkbox's measurements: side, radius,
        // glyph — `checkboxSide`, `checkmarkSide`, `checkboxRadius`.
        let checkboxMeasure = try NSRegularExpression(
            pattern: "\\b(?:let|var)\\s+\\w*(?:[Cc]heckbox|[Cc]heckmark)\\w*"
        )
        var callers: [String: Set<String>] = [:]
        for (name, code) in try Self.strippedGatedSources() {
            // Tokens, not substrings: `ChromeQueryToggle(` in SearchBarView,
            // ProjectSearchView and ChromeControls carries `Toggle(`, and a bare
            // `contains` would be red on day one. `toggleStyle` is matched
            // without its leading dot, because `containsToken` rejects a dotted
            // needle whenever the dot follows an identifier character
            // (`view.toggleStyle(`).
            for token in [
                "Toggle", "toggleStyle",
                "BorderedButtonStyle", "BorderedProminentButtonStyle", "LinkButtonStyle", "DefaultButtonStyle",
            ] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(token, in: code),
                    "\(name) spells \(token) — a gated surface uses the shared checkbox and button styles, not the platform's"
                )
            }
            // Scoped to each `.buttonStyle(`'s own argument: a bare `link` token
            // file-wide would hit unrelated identifiers. `plain` and `borderless`
            // stay allowed — the icon-button idiom throughout the gated set.
            for argument in Self.matchedArguments(after: ".buttonStyle", in: code) {
                for style in ["bordered", "borderedProminent", "link", "automatic"] {
                    XCTAssertFalse(
                        LSPSourceGatingTests.containsToken(style, in: argument),
                        "\(name) applies .buttonStyle(.\(style)) — a platform button style; use .chromePrimary, .chromeSecondary or .plain"
                    )
                }
            }
            if name != "ChromeControls.swift" {
                XCTAssertNil(
                    checkboxMeasure.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                    "\(name) declares a checkbox measurement of its own — the checkbox's side, radius and glyph are ChromeControls.swift's"
                )
            }
            if let expected = Self.partFiveDButtonCounts[name] {
                let actual = (buttons: Self.tokenCount("Button", in: code), styled: Self.tokenCount("buttonStyle", in: code))
                XCTAssertTrue(
                    actual == expected,
                    """
                    \(name) constructs \(actual.buttons) Button and styles \(actual.styled), pinned as \
                    \(expected.buttons) and \(expected.styled) — restate both, style a new button that can \
                    take a style, and name one that cannot in the entry's comment
                    """
                )
            }
            if let expected = Self.partFiveBButtonCounts[name] ?? Self.partFiveCButtonCounts[name] {
                let buttons = Self.tokenCount("Button", in: code)
                XCTAssertEqual(
                    buttons, Self.tokenCount("buttonStyle", in: code),
                    "\(name) constructs a Button it does not style — every button in part five (b)'s and (c)'s files names a style"
                )
                XCTAssertEqual(
                    buttons, expected,
                    "\(name)'s Button count moved — restate it here, and style the new one"
                )
            }
        }
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            for (token, _) in Self.sharedControlCallers where LSPSourceGatingTests.containsToken(token, in: code) {
                callers[token, default: []].insert(url.lastPathComponent)
            }
        }
        for (token, files) in Self.sharedControlCallers {
            XCTAssertEqual(
                callers[token, default: []], files,
                "the files spelling \(token) must be exactly its pinned callers plus the defining file"
            )
        }
    }

    /// The parenthesised argument lists of each call of `modifier`, found through
    /// `callRanges(_:in:)` and brace-matched so a multi-line argument is read
    /// whole.
    private static func matchedArguments(after modifier: String, in code: String) -> [String] {
        callRanges(modifier + "(", in: code).compactMap { call in
            let open = code.index(before: call.upperBound)
            return balancedEnd(from: open, in: code).map { String(code[open..<$0]) }
        }
    }

    // MARK: - Rule thirty-one: a code pane's ground goes through one definition

    /// The four callers of `CodePaneGround.apply(`: the editor, the diff panes,
    /// the merge panes and the source viewer.
    private static let codePaneGroundCallers: Set<String> = [
        "CodeEditorView.swift",
        "SourceViewerContent.swift",
        "DiffView.swift",
        "MergeView.swift",
    ]

    /// Every non-layer `backgroundColor` assignment the rule allows outside
    /// `CodePaneGround`'s body, by file **and count** — so a second assignment
    /// in a pinned file fails as surely as a first one anywhere else. Each pin
    /// carries its reason: removing one later is a decision somebody reads.
    private static let pinnedBackgroundAssignments: [String: (count: Int, reason: String)] = [
        "EscClosableWindow.swift": (1, "the secondary window's ground, set in the subclass (rule twenty-eight)"),
        "MainWindowChrome.swift": (1, "the main window's ground, owned by the window-chrome rule"),
        "CompletionPanel.swift": (
            1, "`.clear` on a borderless NSPanel, which must stay clear for its own rounded layer to draw — not a code pane"
        ),
        "HoverPanel.swift": (
            1, "`.clear` on a borderless NSPanel, which must stay clear for its own rounded layer to draw — not a code pane"
        ),
        "ProjectSearchView.swift": (1, "a text attribute's background, not a view's"),
        "LicenseTextView.swift": (
            1, "the unswept iOS half's `.clear` on a UITextView, so the screen's ground shows through — not a code pane"
        ),
    ]

    /// **Total, and it resolves no types.** Across the gated set plus
    /// `CodeEditorView.swift`, every `backgroundColor` assignment that is not a
    /// layer's (a layer's takes a `CGColor` and is rule twenty-five's) lies
    /// inside `CodePaneGround`'s brace-matched body or is one of
    /// `pinnedBackgroundAssignments`, matched by file and exact count.
    ///
    /// What it no longer claims: it does not identify which object is a code
    /// pane, because it no longer needs to — it forbids the assignment outright
    /// outside the sanctioned sites. The earlier form resolved each receiver's
    /// type from its declarations and, three rounds running, let through a
    /// receiver it could not follow (a clip view bound from a pane's property,
    /// an unwrapped alias, a name the suffix fallback misread). A receiver
    /// spelled any way at all is now the same assignment to this rule.
    func testACodePanesGroundGoesThroughOneDefinition() throws {
        let call = try NSRegularExpression(pattern: "\\bCodePaneGround\\s*\\.\\s*apply\\s*\\(")
        var callers: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if call.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                callers.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            callers, Self.codePaneGroundCallers,
            "the files calling CodePaneGround.apply( must be exactly the editor, the diff and merge panes and the source viewer"
        )

        var scanned = try Self.strippedGatedSources()
        scanned.append((
            "CodeEditorView.swift",
            LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: "CodeEditorView.swift"))
            )
        ))
        var sawDefinition = false
        var counted: [String: Int] = [:]
        for (name, original) in scanned {
            var code = original
            if name == "DiffView.swift" {
                let definition = try XCTUnwrap(
                    Self.matchedBody(after: "enum CodePaneGround", in: code),
                    "CodePaneGround is gone or renamed — re-point this rule rather than losing it"
                )
                code = code.replacingOccurrences(of: definition, with: "")
                sawDefinition = true
            }
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("NSBox", in: code),
                "\(name) spells NSBox — a pane divider is DiffDividerView, a hairline on the role"
            )
            let found = try Self.viewBackgroundAssignmentCount(in: code)
            if found > 0 { counted[name] = found }
        }
        XCTAssertTrue(sawDefinition, "DiffView.swift is no longer gated — re-point this rule rather than losing it")

        for name in Set(counted.keys).union(Self.pinnedBackgroundAssignments.keys).sorted() {
            let found = counted[name] ?? 0
            guard let pin = Self.pinnedBackgroundAssignments[name] else {
                XCTFail(
                    "\(name) assigns a view's backgroundColor \(found) time(s) outside CodePaneGround — "
                        + "a code pane's ground has one definition, and no other site is sanctioned"
                )
                continue
            }
            XCTAssertEqual(
                found, pin.count,
                "\(name) must assign a view's backgroundColor exactly \(pin.count) time(s) (\(pin.reason)); "
                    + "a second assignment is a second ground, a missing one means the pin is stale"
            )
        }

        let merge = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "MergeView.swift"))
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("DiffDividerView", in: merge),
            "MergeView.swift no longer builds its dividers from DiffDividerView — the pane divider is one view"
        )
    }

    /// The `backgroundColor` assignments in `code` that are not a layer's: every
    /// `backgroundColor =` minus those written `layer.`/`layer?.`/`layer!.`. The
    /// receiver is otherwise not read at all — that is the rule's whole point.
    static func viewBackgroundAssignmentCount(in code: String) throws -> Int {
        let range = NSRange(code.startIndex..., in: code)
        let all = try NSRegularExpression(pattern: "\\bbackgroundColor\\s*=(?!=)")
        let layer = try NSRegularExpression(pattern: "\\blayer\\s*[?!]?\\s*\\.\\s*backgroundColor\\s*=(?!=)")
        return all.numberOfMatches(in: code, range: range) - layer.numberOfMatches(in: code, range: range)
    }

    /// Part five (b) deleted the editor's private pane-ground helper when
    /// `makeNSView` began calling `CodePaneGround.apply` directly, and five
    /// architecture passages went on naming it — the entry a reader is told to
    /// consult before editing a file named a function that was not there. So the
    /// old name is pinned **absent** from `docs/architecture/`. `docs/plans/` is
    /// deliberately outside the scan: the plan archive records what was planned,
    /// which offered both shapes, and rewriting it to match the outcome is how an
    /// archive stops being evidence.
    func testNoArchitectureDocumentNamesTheDeletedPaneGroundHelper() throws {
        let directory = try Self.document("docs/architecture")
        let documents = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertFalse(documents.isEmpty, "found no architecture documents — the walk is broken, not the prose")
        let deleted = "applyEditorBackground"
        for url in documents where try Self.read(url).contains(deleted) {
            XCTFail(
                "\(url.lastPathComponent) names \(deleted), which no longer exists — the caller is CodeEditorView.makeNSView"
            )
        }
    }

    /// The positive half: every passage that enumerates `CodePaneGround`'s
    /// callers names exactly the files `codePaneGroundCallers` pins. A backticked
    /// `X.swift` counts as that file; any other backticked token counts as the
    /// file declaring the type its leading identifier names (so
    /// `DiffView.makePane` is `DiffView.swift`), and a token naming no declared
    /// type counts as nothing — a vague caller ("the merge panes") is therefore
    /// a missing one, and the set comparison says so.
    private static let codePaneGroundCallerPassages: [(document: String, start: String, end: String)] = [
        // Rule thirty-one's canonical entry, opened after its heading, which
        // spells `CodePaneGround.apply(` and would count the defining file.
        ("docs/architecture/core-theme.md", "is called in exactly", ";"),
        ("docs/architecture/core-theme.md", "**Four callers**:", " — the editor"),
        ("docs/architecture/app-git-views.md", "its four callers are", "(rule"),
    ]

    func testTheDocumentsNameThePaneGroundsPinnedCallers() throws {
        var declaringFile: [String: String] = [:]
        let declaration = try NSRegularExpression(pattern: "\\b(?:class|struct|enum|actor)\\s+([A-Za-z_][A-Za-z0-9_]*)")
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let name = Range(match.range(at: 1), in: code) else { continue }
                declaringFile[String(code[name])] = url.lastPathComponent
            }
        }
        let backticked = try NSRegularExpression(pattern: "`([^`]+)`")
        for passage in Self.codePaneGroundCallerPassages {
            let text = try Self.read(Self.document(passage.document))
            let start = try XCTUnwrap(
                text.range(of: passage.start),
                "\(passage.document) no longer opens its caller list with \(passage.start) — re-point this check"
            )
            let rest = text[start.upperBound...]
            let end = try XCTUnwrap(
                rest.range(of: passage.end),
                "\(passage.document)'s caller list no longer ends at \(passage.end) — re-point this check"
            )
            let list = String(rest[..<end.lowerBound])
            var named: Set<String> = []
            for match in backticked.matches(in: list, range: NSRange(list.startIndex..., in: list)) {
                guard let range = Range(match.range(at: 1), in: list) else { continue }
                let token = String(list[range])
                if token.hasSuffix(".swift") {
                    named.insert(token)
                } else if let type = token.split(separator: ".").first,
                          let file = declaringFile[String(type)] {
                    named.insert(file)
                }
            }
            XCTAssertEqual(
                named, Self.codePaneGroundCallers,
                "\(passage.document)'s list after \(passage.start) must name exactly the CodePaneGround callers the suite pins"
            )
        }
    }

    // MARK: - Rule thirty-two: a window root resolves the theme the root way

    /// The roots that resolve their colours through a private `chromeColor(_:)`
    /// over `settings.chromeTheme(systemPrefersDark:)`.
    /// `SourceViewerContent` is a root that paints no SwiftUI colour — its one
    /// colour is the AppKit pane ground — so it declares none.
    private static let chromeColorRoots: Set<String> = [
        "ContentView.swift",
        "ProjectSearchView.swift",
        "DiffWindowContent.swift",
        "MergeView.swift",
        "LocalHistoryView.swift",
        "LeetCodeBrowserView.swift",
    ]

    /// A root injects `\.chromeTheme` for its subtree, so it cannot read it: its
    /// own environment is its *parent's*, which at a window root is the resting
    /// appearance. The region checked is the root struct's **whole**
    /// brace-matched declaration, not its `var body`: the regression this rule
    /// exists for is an `@Environment(\.chromeTheme)` stored property added to a
    /// root, and that property sits in the struct's braces, outside `body` — a
    /// clause matched against `body` alone would be vacuous on exactly that
    /// mistake. Child views read the environment from file scope.
    ///
    /// Matched as `containsToken("\\.chromeTheme", …)`: the backslash keeps the
    /// root's own `settings.chromeTheme(` from being a hit, and the trailing
    /// boundary rejects `.chromeThemed(`.
    func testAWindowRootResolvesTheThemeTheRootWay() throws {
        let declaration = try NSRegularExpression(pattern: "\\bfunc\\s+chromeColor\\b")
        var declaring: Set<String> = []
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if declaration.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                declaring.insert(url.lastPathComponent)
            }
        }
        XCTAssertEqual(
            declaring, Self.chromeColorRoots,
            "the files declaring a private chromeColor(_:) must be exactly the six swept window roots"
        )

        let roots = ZoomSourceGatingTests.interfaceScaledRoots.intersection(Self.gatedFiles)
        XCTAssertFalse(roots.isEmpty)
        for name in roots.sorted() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: name))
            )
            let region = try XCTUnwrap(
                Self.rootStructDeclaration(in: code),
                "\(name)'s root struct (the one applying .interfaceScaled() is not found — re-point this rule rather than losing it"
            )
            XCTAssertFalse(
                LSPSourceGatingTests.containsToken("\\.chromeTheme", in: region),
                "\(name)'s root struct reads \\.chromeTheme — a root resolves its colours through chromeColor(_:); only file-scope children read the environment"
            )
        }
    }

    /// The outermost struct whose brace-matched declaration contains the file's
    /// first `.interfaceScaled(` — the window root.
    private static func rootStructDeclaration(in code: String) -> String? {
        guard let scaled = callRanges(".interfaceScaled(", in: code).first else { return nil }
        guard let pattern = try? NSRegularExpression(pattern: "\\bstruct\\s+[A-Za-z_][A-Za-z0-9_]*") else { return nil }
        for match in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range, in: code),
                  let open = code[range.upperBound...].firstIndex(of: "{"),
                  let end = balancedEnd(from: open, in: code) else { continue }
            if range.lowerBound < scaled.lowerBound, scaled.upperBound <= end {
                return String(code[range.lowerBound..<end])
            }
        }
        return nil
    }

    // MARK: - Rule thirty-three: the commit dialog's rows and controls

    /// The commit file row is sized by its two text lines and its padding, never
    /// a fixed height — a fixed height clips the second line at a larger interface
    /// scale, which renders perfectly at the reviewer's; it draws the tree row's
    /// three states in their established precedence; the shared checkbox speaks
    /// its state as a value (its box is hidden); and the merge strip's two
    /// icon-only chevrons carry a name of their own.
    func testTheCommitDialogsRowsAndControls() throws {
        let dialog = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "CommitDialogView.swift"))
        )
        let row = try XCTUnwrap(
            Self.matchedBody(after: "struct CommitFileRow", in: dialog),
            "CommitFileRow is gone or renamed — re-point this rule rather than losing it"
        )
        XCTAssertFalse(
            try Self.hasFrameHeight(in: row),
            "CommitFileRow applies .frame(height: — the row carries no fixed height, sized by its two lines and padding"
        )
        // The row paints the tree's states by *calling* the tree's one mapping.
        // This rule used to require the three role tokens in the row's body,
        // which pinned a copied state→role table in place: the day the tree's
        // mapping changed, the dialog kept the old roles and nothing failed.
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("TreeRowBackground", in: row),
            "CommitFileRow no longer names TreeRowBackground — the row paints the tree's states through the tree's one mapping"
        )
        // The detector is checked against the one table it must find, so it
        // cannot quietly stop recognizing a copy.
        let tree = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "ProjectTreeView.swift"))
        )
        XCTAssertEqual(
            Self.rowStateSwitchesSpellingATreeRole(in: tree).count, 1,
            "the row-state switch detector no longer finds TreeRowBackground.role(for:)'s own table — "
                + "re-point it rather than losing the rule"
        )
        for (name, code) in try Self.strippedGatedSources() where name != "ProjectTreeView.swift" {
            XCTAssertTrue(
                Self.rowStateSwitchesSpellingATreeRole(in: code).isEmpty,
                "\(name) switches over a row state and spells a tree row role itself — call TreeRowBackground.color(for:resolving:), the one mapping, rather than copying its table"
            )
        }

        let controls = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(Self.source(named: "ChromeControls.swift"))
        )
        let checkbox = try XCTUnwrap(
            Self.matchedBody(after: "struct ChromeCheckbox", in: controls),
            "ChromeCheckbox is gone or renamed — re-point this rule rather than losing it"
        )
        // Bare, for the leading-dot reason rule thirty states.
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("accessibilityValue", in: checkbox),
            "ChromeCheckbox no longer speaks its state — its box is hidden, so the value is the only thing that says On, Off or Mixed"
        )

        // Comments stripped, literals kept: the chevrons are found by their
        // symbol names, which are literals the usual scanner deletes.
        let merge = GitHubSourceGatingTests.strippingComments(
            try Self.read(Self.source(named: "MergeView.swift"))
        )
        let strip = try XCTUnwrap(
            Self.matchedBody(after: "private var statusStrip", in: merge),
            "MergeView's statusStrip is gone or renamed — re-point this rule rather than losing it"
        )
        var chevrons = 0
        var searchStart = strip.startIndex
        while let found = strip.range(of: "\"chevron.", range: searchStart..<strip.endIndex) {
            chevrons += 1
            searchStart = found.upperBound
            XCTAssertTrue(
                Self.enclosingBlockChainNames("accessibilityLabel", at: found.lowerBound, in: strip),
                "a merge strip chevron's button carries no accessibilityLabel — an icon-only control reads out as its glyph"
            )
        }
        XCTAssertEqual(chevrons, 2, "the merge strip's two chevrons are gone or renamed — re-point this rule rather than losing it")
    }

    /// Every `switch` body in `code` whose cases name a selected row state
    /// (`selectedFocused`/`selectedUnfocused`) and that spells one of the three
    /// roles `TreeRowBackground.role(for:)` answers with — a copy of the tree's
    /// state→role table, wherever it is written and however it is wrapped.
    static func rowStateSwitchesSpellingATreeRole(in code: String) -> [String] {
        var copies: [String] = []
        var rest = code[...]
        while let found = rest.range(of: "switch") {
            rest = code[found.upperBound...]
            let before = found.lowerBound > code.startIndex ? code[code.index(before: found.lowerBound)] : " "
            let after = found.upperBound < code.endIndex ? code[found.upperBound] : " "
            guard !(before.isLetter || before.isNumber || before == "_"),
                  !(after.isLetter || after.isNumber || after == "_"),
                  let open = code[found.upperBound...].firstIndex(of: "{"),
                  let end = balancedEnd(from: open, in: code) else { continue }
            let body = String(code[open..<end])
            let namesSelectedState = ["selectedFocused", "selectedUnfocused"].contains {
                LSPSourceGatingTests.containsToken($0, in: body)
            }
            let spellsTreeRole = ["accentTintStrong", "selectionInactive", "hoverTint"].contains {
                LSPSourceGatingTests.containsToken($0, in: body)
            }
            if namesSelectedState && spellsTreeRole { copies.append(body) }
        }
        return copies
    }

    /// Whether the modifier chain of the innermost brace block enclosing `index`
    /// — a button's `label:` closure, for a glyph inside it — names `token`.
    private static func enclosingBlockChainNames(_ token: String, at index: String.Index, in code: String) -> Bool {
        var depth = 0
        var cursor = index
        while cursor > code.startIndex {
            cursor = code.index(before: cursor)
            if code[cursor] == "}" { depth += 1 }
            if code[cursor] == "{" {
                if depth > 0 { depth -= 1; continue }
                guard let end = balancedEnd(from: cursor, in: code) else { return false }
                return LSPSourceGatingTests.containsToken(token, in: String(modifierChain(from: end, in: code)))
            }
        }
        return false
    }

    // MARK: - Rule thirty-four: every chrome glyph is sized in the interface zone

    /// A symbol image's size is its font's, and a glyph that sets none takes
    /// whatever an ancestor supplies — or the system default when nothing does,
    /// which is in neither zone and does not move with the interface scale. The
    /// commit dialog's file-type glyph was exactly that: its row lost the
    /// container font it inherited, the name, directory and status letter beside
    /// it each gained a font of their own, and the glyph stood still at 150% and
    /// 200% while everything around it grew. Nothing misrenders at the scale a
    /// reviewer happens to use.
    ///
    /// So every `Image(systemName:` in a gated file carries, among its **own**
    /// chained modifiers (a nested view's modifier inside an argument does not
    /// count), a `.font(` whose argument list names `metrics`, or a `.frame(`
    /// naming `metrics` on a chain that is also `.resizable()` — or sits in a
    /// declaration pinned below, with the exact number of glyphs that
    /// declaration sizes from outside and **what** sizes them, which the rule
    /// re-checks. A declaration is named by the first occurrence of its text in
    /// the stripped file, which is `matchedBody(after:in:)`'s reading.
    ///
    /// Re-checking the "what" is the half that matters: a container font is
    /// exactly what the commit row lost, and an exemption that only counted its
    /// glyphs would stay green through that very regression.
    ///
    /// **A frame alone is not a size.** A symbol that is not `.resizable()`
    /// draws at its font's size whatever frame it is given; the frame reserves
    /// layout space and nothing more. The rule's first shape accepted a metrics
    /// frame on its own, which took the switcher rows' three icon-column glyphs
    /// out of the unsized set — and with them out of the container-font
    /// re-check, so deleting the row's font left the gate green while the three
    /// fell to the system default. They are pinned below as what they are.
    ///
    /// The glyphs are found through `callRanges(_:in:)`, so an
    /// `Image(\n    systemName: …)` is the same glyph: the rule's first shape
    /// searched the contiguous text and skipped a wrapped one outright.
    private enum GlyphSizing {
        /// An enclosing stack's own chain ends in `.font(` naming `metrics`, so
        /// the glyph and the text beside it are one size by construction.
        case containerFont
        /// The glyph lives in a declaration used as a view elsewhere in the same
        /// file; every use of that name is font-sized the `containerFont` way.
        case useSiteFont(String)
        /// The glyph is a button label, and the enclosing button's chain names
        /// this shared style, which sets the label's font through the metrics.
        case buttonStyle(String)
        /// Deliberately on neither scale; the reason is stated at the entry.
        case offBothScales
    }

    private static let glyphSizeExemptions: [(file: String, declaration: String, count: Int, sizing: GlyphSizing)] = [
        // The conflict chevrons are button labels; `ChromeSecondaryButtonStyle`
        // sets the label's `.callout` font through the interface metrics.
        ("MergeView.swift", "private var statusStrip", 2, .buttonStyle("chromeSecondary")),
        // The shared field's leading glyph sits in the field's `HStack`, whose
        // `.font(metrics.scaledFont(textStyle))` is the field's own text size —
        // the glyph matching the text beside it is the point.
        ("ChromeControls.swift", "struct ChromeThemedTextField", 1, .containerFont),
        // Container fonts, one per row or label: the bottom-bar widgets' labels,
        ("BranchSwitcherView.swift", "var body: some View", 2, .containerFont),
        ("ProjectSwitcherView.swift", "var body: some View", 2, .containerFont),
        ("PullRequestIndicatorView.swift", "var body: some View", 2, .containerFont),
        // the switcher popovers' three rows, whose glyph sits in a 16-point icon
        // column — a `.frame(width:)` that aligns the names and sizes nothing,
        // the symbol not being resizable — under the row `HStack`'s body font,
        ("BranchSwitcherView.swift", "private func branchRow(", 1, .containerFont),
        ("BranchSwitcherView.swift", "private func remoteBranchRow(", 1, .containerFont),
        ("ProjectSwitcherView.swift", "private func projectRow(", 1, .containerFont),
        // the consent strip's three rows,
        ("LSPConsentBanner.swift", "private func downloadRow(", 1, .containerFont),
        ("LSPConsentBanner.swift", "private func goRow(", 1, .containerFont),
        ("LSPConsentBanner.swift", "private func rustRow(", 1, .containerFont),
        // the dock panels' group headers, badges and rows,
        ("ProblemsPanelView.swift", "private func fileGroup(", 1, .containerFont),
        ("ProblemsPanelView.swift", "private func severityBadge(", 1, .containerFont),
        ("ProblemsPanelView.swift", "struct ProblemRow", 1, .containerFont),
        ("UsagesPanelView.swift", "private func fileGroup(", 1, .containerFont),
        ("CommitLogView.swift", "struct CommitFileRow", 1, .containerFont),
        // and the tree's rows.
        ("ProjectTreeView.swift", "struct DirectoryNodeView", 1, .containerFont),
        ("ProjectTreeView.swift", "struct FileRowView", 1, .containerFont),
        // The create draft's icon column is drawn twice — beside the field, and
        // as a hidden twin measuring the reason line's inset — each under a font
        // of its own at the use site.
        ("ProjectTreeDraftField.swift", "private var iconColumn", 2, .useSiteFont("iconColumn")),
        // The unified diff's per-line checkbox is fixed geometry belonging to a
        // *code* row, left off both scales on purpose (the file's own `metrics`
        // comment states it — the Find in Files rows' rule), so neither zone
        // may size it.
        ("CommitUnifiedDiffView.swift", "private func checkbox(for", 1, .offBothScales),
    ]

    func testEveryChromeGlyphIsSizedInTheInterfaceZone() throws {
        var exempted: [String: Int] = [:]
        for exemption in Self.glyphSizeExemptions {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
                try Self.read(Self.source(named: exemption.file))
            )
            let body = try XCTUnwrap(
                Self.matchedBodyRange(after: exemption.declaration, in: code),
                "\(exemption.file)'s \(exemption.declaration) is gone or renamed — re-point its exemption rather than losing it"
            )
            let glyphs = Self.unsizedGlyphs(in: code).filter { body.contains($0) }
            XCTAssertEqual(
                glyphs.count, exemption.count,
                """
                \(exemption.file)'s \(exemption.declaration) is exempted for \(exemption.count) glyph(s) sized \
                from outside — re-derive the count rather than widening it
                """
            )
            exempted[exemption.file, default: 0] += exemption.count
            switch exemption.sizing {
            case .containerFont:
                for glyph in glyphs {
                    XCTAssertTrue(
                        Self.enclosingChainSetsAScaledFont(at: glyph, in: code),
                        """
                        a glyph in \(exemption.file)'s \(exemption.declaration) is exempted for its container font, \
                        and no enclosing stack sets .font( naming metrics any more — size the glyph itself
                        """
                    )
                }
            case .useSiteFont(let name):
                var uses = 0
                var searchStart = code.startIndex
                while let found = code.range(of: name, range: searchStart..<code.endIndex) {
                    searchStart = found.upperBound
                    guard Self.isWholeToken(found, in: code), !body.contains(found.lowerBound) else { continue }
                    let after = code[found.upperBound...].first { !$0.isWhitespace }
                    if after == ":" { continue } // the declaration itself
                    uses += 1
                    XCTAssertTrue(
                        Self.chainSetsAScaledFont(from: found.upperBound, in: code)
                            || Self.enclosingChainSetsAScaledFont(at: found.lowerBound, in: code),
                        "a use of \(name) in \(exemption.file) is not under a .font( naming metrics — its glyphs draw unsized"
                    )
                }
                XCTAssertGreaterThan(uses, 0, "\(name) is used nowhere in \(exemption.file) — re-point this exemption")
            case .buttonStyle(let style):
                for glyph in glyphs {
                    XCTAssertTrue(
                        Self.enclosingBlockChainNames(style, at: glyph, in: code),
                        """
                        a glyph in \(exemption.file)'s \(exemption.declaration) is exempted for its button's \
                        \(style) style, and its button no longer names it — size the glyph itself
                        """
                    )
                }
            case .offBothScales:
                break
            }
        }
        for (name, code) in try Self.strippedGatedSources() {
            XCTAssertEqual(
                Self.unsizedGlyphs(in: code).count, exempted[name, default: 0],
                """
                \(name) has an Image(systemName:) with no .font( naming metrics among its own modifiers \
                (a metrics .frame( counts only beside .resizable()) — size it in the interface zone, or pin \
                the declaration that sizes it with the reason
                """
            )
        }
    }

    /// The positions of the `Image(systemName:` occurrences in `code` whose own
    /// modifier chain sizes nothing through `metrics`.
    static func unsizedGlyphs(in code: String) -> [String.Index] {
        var positions: [String.Index] = []
        for found in callRanges("Image(systemName:", in: code) {
            guard let open = code[found].firstIndex(of: "(") else { continue }
            if let end = balancedEnd(from: open, in: code) {
                if chainSizesThroughMetrics(from: end, in: code, links: ["font"]) { continue }
                // A frame sizes a symbol only once the symbol is resizable; an
                // un-resizable one draws at its font's size whatever frame it
                // is given, the frame reserving layout space and nothing more.
                if chainSizesThroughMetrics(from: end, in: code, links: ["frame"]),
                   chainLinks(from: end, in: code).contains(where: { $0.name == "resizable" }) {
                    continue
                }
            }
            positions.append(found.lowerBound)
        }
        return positions
    }

    /// Whether the text at `range` starts on an identifier boundary.
    private static func isWholeToken(_ range: Range<String.Index>, in code: String) -> Bool {
        guard range.lowerBound > code.startIndex else { return true }
        let before = code[code.index(before: range.lowerBound)]
        return !(before.isLetter || before.isNumber || before == "_")
    }

    private static func chainSetsAScaledFont(from start: String.Index, in code: String) -> Bool {
        chainSizesThroughMetrics(from: start, in: code, links: ["font"])
    }

    /// Whether any brace block enclosing `index` — walking outward to the top of
    /// the file — is followed by a modifier chain setting `.font(` through
    /// `metrics`. A block whose chain is empty (an `if`, a `switch` case) passes
    /// the question outward, which is how an `if let glyph { Image … }` inside a
    /// fonted `HStack` is found.
    private static func enclosingChainSetsAScaledFont(at index: String.Index, in code: String) -> Bool {
        var depth = 0
        var cursor = index
        while cursor > code.startIndex {
            cursor = code.index(before: cursor)
            if code[cursor] == "}" { depth += 1 }
            if code[cursor] == "{" {
                if depth > 0 { depth -= 1; continue }
                guard let end = balancedEnd(from: cursor, in: code) else { return false }
                if chainSetsAScaledFont(from: end, in: code) { return true }
            }
        }
        return false
    }

    /// Whether a top-level link of the modifier chain at `start` is one of
    /// `links` with `metrics` in its own argument list.
    private static func chainSizesThroughMetrics(from start: String.Index, in code: String, links: Set<String>) -> Bool {
        chainLinks(from: start, in: code).contains { link in
            links.contains(link.name) && LSPSourceGatingTests.containsToken("metrics", in: link.arguments)
        }
    }

    /// The top-level links of the modifier chain at `start`, in order: each
    /// link's name and its own parenthesised argument list (empty when it has
    /// none). Walks the links `modifierChain(from:in:)` walks — a trailing
    /// closure is stepped over, and a nested view's modifier inside an argument
    /// is not a link of this chain.
    private static func chainLinks(from start: String.Index, in code: String) -> [(name: String, arguments: String)] {
        var links: [(name: String, arguments: String)] = []
        var index = start
        func skip(_ allowed: (Character) -> Bool) {
            while index < code.endIndex, allowed(code[index]) { index = code.index(after: index) }
        }
        while true {
            skip { $0.isWhitespace }
            guard index < code.endIndex, code[index] == "." else { return links }
            index = code.index(after: index)
            let nameStart = index
            skip { $0.isLetter || $0.isNumber || $0 == "_" }
            let name = String(code[nameStart..<index])
            var arguments = ""
            if index < code.endIndex, code[index] == "(" {
                guard let past = balancedEnd(from: index, in: code) else { return links }
                arguments = String(code[index..<past])
                index = past
            }
            links.append((name, arguments))
            skip { $0 == " " || $0 == "\t" }
            if index < code.endIndex, code[index] == "{" {
                guard let past = balancedEnd(from: index, in: code) else { return links }
                index = past
            }
        }
    }

    // MARK: - Rule thirty-five: a selectable list yields its selected row's background

    /// Every selectable `List` in the gated files, pinned: file name → one entry
    /// per `List` construction binding `selection:` (in source order), each entry
    /// the whitespace-normalized text of every `listRowBackground` argument in
    /// that list's content closure (in source order). Each pinned expression was
    /// read by a person and confirmed to yield the selected row's background.
    private static let selectableListBackgrounds: [String: [[String]]] = [
        "LocalHistoryView.swift": [
            ["snapshot.fileName == selection.wrappedValue ? Color.clear : chromeColor(.bgPanel)"],
        ],
        // The dependency list sets no row background at all: the platform draws
        // the selection, and nothing paints over it.
        "AcknowledgementsView.swift": [[]],
        // The database viewer's tables-and-views sidebar, the same answer: the
        // platform draws the selection and no row paints a background.
        "DatabaseViewerView.swift": [[]],
    ]

    /// On macOS a `listRowBackground` is drawn **over** the selection box the
    /// platform draws for its row, so a list that binds `selection:` and gives
    /// every row a background shows no selection at all. The Local History
    /// window's revisions list shipped exactly that way: the selected revision —
    /// the one Restore applies — looked like every other row. Its comment cited
    /// Find in Files as the precedent, but that list binds no selection, so the
    /// precedent never carried.
    ///
    /// The rule **does not read the conditional**. It pins, by equality in both
    /// directions, every row background of every selectable list against
    /// `selectableListBackgrounds`: a selectable list not in the pin fails, a pin
    /// with no list behind it fails, and a background whose text differs from
    /// its pinned entry fails. Only whitespace runs are collapsed, so any other
    /// reformat — added parentheses, a renamed row, the branches reordered —
    /// fails too, and that is deliberate: a rule that cannot read an expression
    /// refuses to guess what it means, and a person confirms the selected row
    /// still yields its background before updating the pin. The construction is
    /// found through `callRanges(_:in:)`, so a `List` whose paren sits on the
    /// next line is still seen, and each background's argument list is read
    /// brace-matched, so a multi-line expression is read whole.
    func testASelectableListYieldsItsSelectedRowsBackground() throws {
        var found: [String: [[String]]] = [:]
        for (name, code) in try Self.strippedGatedSources() {
            for call in Self.callRanges("List(", in: code) {
                let open = code.index(before: call.upperBound)
                guard let close = Self.balancedEnd(from: open, in: code) else { continue }
                let arguments = String(code[code.index(after: open)..<code.index(before: close)])
                let isSelectable = Self.topLevelArguments(arguments).contains {
                    $0.range(of: "^selection\\s*:", options: .regularExpression) != nil
                }
                guard isSelectable else { continue }
                var backgrounds: [String] = []
                var cursor = close
                while cursor < code.endIndex, code[cursor].isWhitespace { cursor = code.index(after: cursor) }
                if cursor < code.endIndex, code[cursor] == "{",
                   let contentEnd = Self.balancedEnd(from: cursor, in: code) {
                    let content = String(code[cursor..<contentEnd])
                    backgrounds = Self.matchedArguments(after: ".listRowBackground", in: content).map {
                        String($0.dropFirst().dropLast())
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                    }
                }
                found[name, default: []].append(backgrounds)
            }
        }
        XCTAssertEqual(
            found, Self.selectableListBackgrounds,
            """
            a selectable List or one of its listRowBackground expressions changed. A row background is drawn over \
            the platform's selection box, and this rule cannot read the expression, so it refuses to guess: confirm \
            by reading the code that the selected row still yields its background (e.g. `row == selection ? \
            Color.clear : <background>`), then update selectableListBackgrounds to the new text
            """
        )
    }

    /// The top-level, comma-separated arguments of an argument list's inside —
    /// a comma nested in parentheses, brackets or braces does not split. The
    /// suite's one comma splitter: a rule needing top-level arguments goes
    /// through here rather than growing a second.
    private static func topLevelArguments(_ arguments: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in arguments {
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    /// Every call `needle` spells in `code`, where `needle` is written the way a
    /// contiguous search would have spelled it — a callee, its opening
    /// parenthesis, and optionally the start of its argument list:
    /// `"List("`, `"Image(systemName:"`, `".lineLimit(1)"`,
    /// `".overlay(alignment: .bottom)"`. Whitespace — newlines included — is
    /// tolerated between any two tokens of the needle — the callee and its
    /// parenthesis, a label and its colon, two arguments — so `Image(\n    systemName: …)` is the call
    /// `"Image(systemName:"` names. A callee not led by `.` must start on an
    /// identifier boundary (`NSImage(` is not `Image(`); a modifier's dot is its
    /// own boundary. Each range runs from the callee's first character through
    /// the last character the needle names, so with a bare `"Name("` needle
    /// `code.index(before: range.upperBound)` is the parenthesis. A needle may
    /// end on a trailing closure's brace instead (`".contextMenu {"`), for a
    /// modifier that is spelled without one.
    ///
    /// The suite's one call matcher. A contiguous search is blind to every
    /// wrapped spelling of the call it names, and this suite has shipped that
    /// blindness three times over (rule twenty-one's `.frame(\n height:)`, then
    /// rule thirty-four's multi-line `Image(`); a rule matching a call with
    /// arguments goes through here — or through `callCount(_:in:)` /
    /// `spellsCall(_:in:)` — rather than through `contains` or `range(of:)`.
    static func callRanges(_ needle: String, in code: String) -> [Range<String.Index>] {
        precondition(
            needle.contains("(") || needle.contains("{"),
            "callRanges needs a needle spelling its opening parenthesis or trailing closure's brace: \(needle)"
        )
        let tokens = callTokens(needle)
        let leadsWithIdentifier = tokens.first?.first.map { $0.isLetter || $0 == "_" } ?? false
        let pattern = (leadsWithIdentifier ? "(?<![A-Za-z0-9_])" : "")
            + tokens.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "\\s*")
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("callRanges could not compile \(pattern)")
        }
        return expression.matches(in: code, range: NSRange(code.startIndex..., in: code))
            .compactMap { Range($0.range, in: code) }
    }

    /// The number of calls `needle` names in `code` — `callRanges(_:in:)`'s count.
    static func callCount(_ needle: String, in code: String) -> Int {
        callRanges(needle, in: code).count
    }

    /// Whether `code` spells the call `needle` names at least once.
    static func spellsCall(_ needle: String, in code: String) -> Bool {
        !callRanges(needle, in: code).isEmpty
    }

    /// A needle split into the tokens whitespace may separate: runs of
    /// identifier characters, and every other non-space character on its own.
    private static func callTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
                continue
            }
            if !word.isEmpty { tokens.append(word); word = "" }
            if !character.isWhitespace { tokens.append(String(character)) }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    // MARK: - Rule thirty-six: no gated file builds a platform form control

    /// The platform's form controls — a `Form`, a `Picker` in any style, a
    /// `Stepper`, a `Toggle`, a `TabView` and its `tabItem` — each draw in the
    /// platform's own colours and metrics, compile, and look plausible in
    /// whichever appearance the reviewer is in. The chrome draws a replacement
    /// for every one of them in `ChromeControls.swift`.
    ///
    /// Two already-gated surfaces were swept to make this green on day one: the
    /// commit dialog's author editor (a `Form` of two fields, now two stacked
    /// shared fields) and the Log bar's branch menu (an inline `Picker`, now the
    /// shared menu field's first caller). `Toggle` overlaps rule thirty on
    /// purpose, so the whole family is listed in one place.
    ///
    /// Matched through `containsToken`, so `ChromeStepper(` is not a `Stepper`
    /// and `ChromeQueryToggle(` not a `Toggle`; `pickerStyle` and `tabItem` are
    /// bare for the leading-dot reason rule thirty states.
    private static let platformFormControls = [
        "Form", "Picker", "pickerStyle", "Stepper", "Toggle", "TabView", "tabItem",
    ]

    func testNoGatedFileBuildsAPlatformFormControl() throws {
        for (name, code) in try Self.strippedGatedSources() {
            for token in Self.platformFormControls {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(token, in: code),
                    "\(name) spells \(token) — a gated surface builds the shared chrome control, not the platform's"
                )
            }
        }
    }

    // MARK: - Rule thirty-seven: a picker's shape follows its set, and each settings shape has its pinned callers

    /// Each settings shape's constructions, per calling file. The defining
    /// file, `ChromeControls.swift`, constructs none of them and spells each
    /// only in its declaration, so it is not a key here; the mention rule below
    /// adds it back.
    private static let settingsShapeConstructions: [(token: String, counts: [String: Int])] = [
        ("ChromeSegmentedControl", ["SettingsView.swift": 2, "PullRequestMergeSheet.swift": 1]),
        ("ChromeMenuField", [
            "LogFilterBar.swift": 1, "SettingsView.swift": 1, "NewPullRequestSheet.swift": 1,
            "LeetCodeBrowserView.swift": 1, "LeetCodeOpenProblemSheet.swift": 1,
        ]),
        ("ChromeStepper", ["SettingsView.swift": 2]),
        ("ChromeSwitch", ["SettingsView.swift": 2]),
        ("ChromeSettingsTabBar", ["SettingsView.swift": 1]),
    ]

    /// A picker's shape follows its set: a small set known when the app is
    /// built (the tab placement, the theme, the merge methods) is a segmented
    /// control, and a set read at run time (branches, languages) is a menu
    /// field; a standing preference is a switch, and an option of one action is
    /// a checkbox. The rule cannot read a set's size, so it pins two things
    /// per shape: the files that spell it (the defining file included), by set
    /// equality, and how many times each of those files *constructs* it,
    /// counted through `callRanges(_:in:)` so a wrapped call counts — rule
    /// thirty's shape, applied to the five settings shapes. The sets alone were
    /// blind to a shape change inside a file that already spells both shapes:
    /// `SettingsView.swift` builds two segmented controls and one menu field, so
    /// turning one into the other kept it in both sets. A segmented
    /// base-branch list, a switch where a checkbox belongs, or a second segmented
    /// control added to a pinned file each changes a count or a set and fails
    /// here, and a person decides whether the new shape is right before updating
    /// the pin.
    func testAPickersShapeFollowsItsSetAndEachSettingsShapeHasItsPinnedCallers() throws {
        var callers: [String: Set<String>] = [:]
        var constructions: [String: [String: Int]] = [:]
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let name = url.lastPathComponent
            for (token, _) in Self.settingsShapeConstructions {
                if LSPSourceGatingTests.containsToken(token, in: code) {
                    callers[token, default: []].insert(name)
                }
                let count = Self.callCount("\(token)(", in: code)
                if count > 0 { constructions[token, default: [:]][name] = count }
            }
        }
        for (token, counts) in Self.settingsShapeConstructions {
            XCTAssertEqual(
                callers[token, default: []], Set(counts.keys).union(["ChromeControls.swift"]),
                "the files spelling \(token) must be exactly its pinned callers plus the defining file"
            )
            XCTAssertEqual(
                constructions[token, default: [:]], counts,
                "the constructions of \(token) per file must be exactly the pinned counts — a control changed shape or was added"
            )
        }
    }

    /// The files that frame something at `ChromeGeometry.menuFieldHeight`, with
    /// how many times each spells it. Every one of these is a `ChromeMenuField`
    /// frame — the token is the shared menu field's height and nothing else's;
    /// `ChromeGeometry.swift` is the declaration. The Log bar builds a menu field
    /// too but frames it at its own `FilterBarLayout.controlHeight`, so it is not
    /// a key.
    private static let menuFieldHeightSpellings: [String: Int] = [
        "ChromeGeometry.swift": 1,
        "SettingsView.swift": 1,
        "NewPullRequestSheet.swift": 1,
        "LeetCodeBrowserView.swift": 1,
        "LeetCodeOpenProblemSheet.swift": 1,
    ]

    /// `menuFieldHeight` sizes the menu fields it is named for and no other
    /// control. A text field beside a menu field that borrows the token to line
    /// up is coupled to it silently — changing the menu field's height would
    /// resize a field nothing names — which is the coupling rule seven exists to
    /// prevent, arriving by reuse rather than arithmetic. Two text fields did
    /// exactly that; each now takes its height from its own surface's layout
    /// enum. Pinned per file by count, over every source file, so a new borrower
    /// fails here even in a file that already frames a menu field. The rule
    /// cannot see *what* a spelling frames; that each pinned spelling sits on a
    /// `ChromeMenuField` is checked by reading, and each count equals that
    /// file's pinned menu field constructions above.
    func testTheMenuFieldHeightSizesTheMenuFieldsAlone() throws {
        var spellings: [String: Int] = [:]
        for url in try Self.swiftSources() {
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            let count = code.components(separatedBy: "menuFieldHeight").count - 1
            if count > 0 { spellings[url.lastPathComponent] = count }
        }
        XCTAssertEqual(
            spellings, Self.menuFieldHeightSpellings,
            "the files spelling menuFieldHeight must be exactly its pinned menu-field callers plus the declaration"
                + " — a text field takes its own surface's height"
        )
        let menuFieldCounts = Self.settingsShapeConstructions.first { $0.token == "ChromeMenuField" }?.counts ?? [:]
        for (file, count) in Self.menuFieldHeightSpellings where file != "ChromeGeometry.swift" {
            XCTAssertEqual(
                count, menuFieldCounts[file],
                "\(file) frames \(count) control(s) at menuFieldHeight but constructs \(menuFieldCounts[file] ?? 0) menu field(s)"
            )
        }
    }

    /// The menu field's shape is whole: its chevron is part of the `Menu`'s own
    /// label, so the arrow the field draws is the control. The field was lifted
    /// from the Log bar with the glyph a *sibling* of the `Menu`, which draws
    /// the same and opens nothing when the arrow is clicked — and the lift
    /// carried that to every caller.
    ///
    /// Read as tokens inside matched bodies, not as a view tree: the struct's
    /// body spells exactly one `Image(` (the chevron — the options' checkmark is
    /// a `Label`), and the body matched after `label:` following the `Menu`'s
    /// content closure spells it too, hidden from accessibility there.
    func testTheMenuFieldsChevronIsPartOfItsMenusLabel() throws {
        let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(
            try Self.read(try Self.source(named: "ChromeControls.swift"))
        )
        let field = try XCTUnwrap(
            Self.matchedBody(after: "struct ChromeMenuField", in: code),
            "struct ChromeMenuField is gone or renamed"
        )
        XCTAssertEqual(
            Self.callCount("Image(", in: field), 1,
            "ChromeMenuField must draw exactly one glyph, its chevron"
        )
        let content = try XCTUnwrap(
            Self.matchedBodyRange(after: "Menu", in: field),
            "ChromeMenuField no longer builds a Menu"
        )
        let label = try XCTUnwrap(
            Self.matchedBody(after: "label:", in: String(field[content.upperBound...])),
            "ChromeMenuField's Menu has no label: closure"
        )
        XCTAssertTrue(
            Self.spellsCall("Image(", in: label),
            "ChromeMenuField's chevron sits outside the Menu's label — the arrow it draws opens nothing"
        )
        XCTAssertTrue(
            Self.spellsCall(".accessibilityHidden(true)", in: label),
            "ChromeMenuField's chevron must stay hidden from accessibility inside the label"
        )
    }

    // MARK: - Rule thirty-eight: no gated file builds a platform table

    /// A `Table` draws its header, its grounds, its alternation and its
    /// selection box in the platform's own colours and metrics, none of which a
    /// role reaches — the same wall rule thirty-six names for the form controls.
    /// The problem-catalog browser was the last gated `Table`; its rows are now
    /// the chrome's own, a `LazyVStack` of rows following `CommitRow`.
    ///
    /// Matched through `containsToken`, so `LazyVStack` and identifiers merely
    /// holding "Table" (`DatabaseTable`, `isTableSelected`) are not hits; the
    /// tree was confirmed to spell neither token in any gated file.
    private static let platformTableTokens = ["Table", "TableColumn"]

    func testNoGatedFileBuildsAPlatformTable() throws {
        let sources = try Self.strippedGatedSources()
        for (name, code) in sources {
            for token in Self.platformTableTokens {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(token, in: code),
                    "\(name) spells \(token) — a gated surface draws its own rows, not the platform's table"
                )
            }
        }
        let browser = try XCTUnwrap(
            sources.first { $0.name == "LeetCodeBrowserView.swift" },
            "LeetCodeBrowserView.swift is gone or no longer gated"
        )
        XCTAssertTrue(
            LSPSourceGatingTests.containsToken("LazyVStack", in: browser.code),
            "LeetCodeBrowserView.swift no longer lays its rows out in a LazyVStack"
        )
    }

    // MARK: - Rule thirty-nine: the problem catalog's three colour mappings are Core's one answer each

    /// Which role a problem's difficulty, its status and a judge verdict are
    /// drawn in has one answer each in Core — `ChromeColorRole.difficultyRole(for:)`,
    /// `problemStatusRole(for:)` and `verdictRole(for:matchedExpected:)`, the
    /// last carrying the "good" rule the judge view used to decide with an
    /// `isGood` flag. Rule eighteen's shape over the three: no app file declares
    /// one; the app files reading each equal its one known reader; no gated file
    /// spells `isGood` or `isAccepted`; and the difficulty and status case labels
    /// are pinned by count per gated file.
    ///
    /// The iOS browser keeps its own colour table and is not gated (it is not
    /// part of the macOS sweep); the reader sets are read over every app file,
    /// so it is named nowhere here only because it spells none of the three.
    ///
    /// Stated limit: rule eighteen's — a `switch`'s labels, not a dictionary
    /// keyed by the same values, a chain of `==`, or a `case` list continued past
    /// its first line.
    private static let catalogRoleReaders: [(call: String, readers: Set<String>)] = [
        ("difficultyRole(for:", ["LeetCodeBrowserView.swift"]),
        ("problemStatusRole(for:", ["LeetCodeBrowserView.swift"]),
        ("verdictRole(for:", ["LeetCodeJudgeView.swift"]),
    ]

    /// The gated files spelling a difficulty or status case label, each by its
    /// exact count. The browser's nine are its two title switches (three labels
    /// each) and `statusCell`'s glyph switch (three) — words and a glyph, not a
    /// colour, which is why they stay in the view; a colour switch added later
    /// moves the count.
    private static let catalogCaseLabels: [String: Int] = [
        "LeetCodeBrowserView.swift": 9,
    ]

    func testTheProblemCatalogsColourMappingsAreCoresOneAnswerEach() throws {
        var readers: [String: Set<String>] = [:]
        for url in try Self.swiftSources() where url.path.contains("/Sources/Pisaka/") {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            for declaration in ["func difficultyRole", "func problemStatusRole", "func verdictRole"] {
                XCTAssertFalse(
                    code.contains(declaration),
                    "\(name) declares \(declaration) — the catalog's colours are Core's one answer each"
                )
            }
            for (call, _) in Self.catalogRoleReaders where Self.spellsCall(call, in: code) {
                readers[call, default: []].insert(name)
            }
        }
        for (call, expected) in Self.catalogRoleReaders {
            XCTAssertEqual(
                readers[call, default: []], expected,
                "the app files reading ChromeColorRole.\(call) must be exactly its known reader"
            )
        }

        let cases = "(easy|medium|hard|notStarted|attempted|solved)"
        let labels = try NSRegularExpression(
            pattern: "\\bcase\\b[^:\\n]*\\.\(cases)\\b"
                + "|\\b(LeetCodeDifficulty|LeetCodeProblemStatus)\\.\(cases)\\b"
        )
        for (name, code) in try Self.strippedGatedSources() {
            for flag in ["isGood", "isAccepted"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(flag, in: code),
                    "\(name) spells \(flag) — whether a verdict is good is decided by verdictRole(for:matchedExpected:)"
                )
            }
            XCTAssertEqual(
                labels.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)),
                Self.catalogCaseLabels[name, default: 0],
                """
                \(name) spells a difficulty or status case label beyond its pinned count — a colour \
                mapping in a view is a second table; read ChromeColorRole's Core answer
                """
            )
        }
    }

    // MARK: - Rule forty: one spinner

    /// Activity is drawn by one shape, `ChromeSpinner` — an arc in
    /// `textSecondary` at the two spinner tokens — and never by the platform's
    /// `ProgressView`, which draws in the platform's colours at the platform's
    /// control size and follows neither zoom.
    ///
    /// Three clauses: no gated file spells `ProgressView` or
    /// `progressViewStyle`; the files spelling `ChromeSpinner` equal the
    /// classified callers plus the defining file; and each caller's pair — how
    /// many constructions carry `.accessibilityLabel(` and how many
    /// `.accessibilityHidden(true)`, read with rule twenty's clause — equals its row
    /// in `spinnerClassification`, the pairs summing to the twenty sites. A site
    /// swapping one marker for the other, dropping both or appearing anew moves
    /// a number.
    private static let spinnerSiteCount = 20

    func testOneSpinner() throws {
        for (name, code) in try Self.strippedGatedSources() {
            for token in ["ProgressView", "progressViewStyle"] {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(token, in: code),
                    "\(name) spells \(token) — a gated surface draws the shared ChromeSpinner"
                )
            }
        }

        var spellers: Set<String> = []
        var found: [String: (labelled: Int, hidden: Int)] = [:]
        for url in try Self.swiftSources() {
            let name = url.lastPathComponent
            let code = LSPSourceGatingTests.strippingCommentsAndStringLiterals(try Self.read(url))
            if LSPSourceGatingTests.containsToken("ChromeSpinner", in: code) { spellers.insert(name) }
            let markers = try XCTUnwrap(
                Self.spinnerMarkers(in: code),
                "\(name) constructs a ChromeSpinner whose call does not close"
            )
            guard !markers.isEmpty else { continue }
            found[name] = (
                labelled: markers.filter(\.labelled).count,
                hidden: markers.filter(\.hidden).count
            )
        }
        XCTAssertEqual(
            spellers, Set(Self.spinnerClassification.keys).union(["ChromeControls.swift"]),
            "the files spelling ChromeSpinner must be exactly the classified callers plus the defining file"
        )
        XCTAssertEqual(
            Set(found.keys), Set(Self.spinnerClassification.keys),
            "the files constructing a ChromeSpinner must be exactly the classified ones"
        )
        for (name, pinned) in Self.spinnerClassification {
            let actual = found[name] ?? (labelled: 0, hidden: 0)
            XCTAssertTrue(
                actual == pinned,
                """
                \(name)'s spinners are \(actual.labelled) labelled and \(actual.hidden) hidden, pinned as \
                \(pinned.labelled) and \(pinned.hidden) — reclassify the site against its neighbours
                """
            )
        }
        XCTAssertEqual(
            Self.spinnerClassification.values.reduce(0) { $0 + $1.labelled + $1.hidden },
            Self.spinnerSiteCount,
            "the classified spinner sites must total the twenty the sweep confirmed"
        )
    }

    // MARK: - Rule forty-one: no alternating row fill

    /// The design's tables read by selection and hover, not by alternation: the
    /// database grid and the console's result rows each drew a zebra through an
    /// `isTinted` flag over `isMultiple(of: 2)`, and both are gone. The platform's
    /// own alternation left with the `Table` (rule thirty-eight). No gated file
    /// spells `alternatingRowBackgrounds`, `isMultiple` or `isTinted`, matched
    /// through `containsToken`.
    ///
    /// A second clause reads the ordinary spelling of a zebra, `index % 2 == 0`,
    /// **inside a matched body only**: no row-fill modifier's own text — its
    /// parenthesis-matched argument list and its trailing closure, when it has
    /// one — spells `% 2`. The row-fill modifiers are named as a set,
    /// `rowFillModifiers`: `.background` and `.listRowBackground`, the two a row
    /// fill can go through. Before fix round 02 the clause read `.background`
    /// alone, so a `.listRowBackground(index % 2 == 0 ? … : …)` in the console
    /// stayed green. `%` is not banned across the gated files, which would reach
    /// every arithmetic use in fifty-eight of them; the clause asks for a token
    /// inside the modifiers a row fill goes through and resolves nothing.
    /// Stated limit: a parity computed elsewhere and handed to one of them as a
    /// name (`let fill = …; .background(fill)`) is not seen, nor is a modifier
    /// outside the set. Shown red against `.background(index % 2 == 0 ? … : …)`
    /// in the console's result rows before it was committed; the token clause
    /// alone stayed green on it. The token ban stays the real defence: it is
    /// total across the gated files.
    private static let alternationTokens = ["alternatingRowBackgrounds", "isMultiple", "isTinted"]

    /// The modifiers a row fill can go through, read by the parity clause.
    private static let rowFillModifiers = ["background", "listRowBackground"]

    func testNoAlternatingRowFill() throws {
        for (name, code) in try Self.strippedGatedSources() {
            for token in Self.alternationTokens {
                XCTAssertFalse(
                    LSPSourceGatingTests.containsToken(token, in: code),
                    "\(name) spells \(token) — a gated table reads by selection and hover, never by alternation"
                )
            }
            for text in Self.rowFillModifierTexts(in: code) {
                XCTAssertNil(
                    text.range(of: #"%\s*2(?![0-9])"#, options: .regularExpression),
                    "\(name) fills a background by row parity — a gated table reads by selection and hover"
                )
            }
        }
    }

    /// The text of every `rowFillModifiers` modifier in `code`: its
    /// parenthesis-matched argument list when it has one, followed by its
    /// trailing closure's body when one opens right after — `.background(…)`,
    /// `.background(…) { … }` and `.background { … }` alike, and the same for
    /// `.listRowBackground`. A call that does not close yields nothing.
    private static func rowFillModifierTexts(in code: String) -> [String] {
        let names = rowFillModifiers.joined(separator: "|")
        guard let expression = try? NSRegularExpression(pattern: #"\.\s*(?:"# + names + #")(?![A-Za-z0-9_])"#) else {
            preconditionFailure("rowFillModifierTexts could not compile its pattern")
        }
        return expression.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { match in
            guard let found = Range(match.range, in: code) else { return nil }
            var text = ""
            var after = found.upperBound
            let gap = code[after...].prefix { $0.isWhitespace }
            if gap.endIndex < code.endIndex, code[gap.endIndex] == "(" {
                guard let end = balancedEnd(from: gap.endIndex, in: code) else { return nil }
                text += code[gap.endIndex..<end]
                after = end
            }
            if let body = trailingBody(from: after, in: Substring(code)) { text += body }
            return text
        }
    }

    // MARK: - Self-check

    /// Every gated file draws with roles and must therefore name one — with two
    /// exceptions: `ChromeThemeEnvironment.swift` carries the *appearance* down
    /// the tree and paints nothing, and `CommitGraphView.swift` draws only lanes,
    /// whose colours are `CommitGraphPalette`'s (the fourth exemption) rather
    /// than roles — so each names no role by construction. Both stay gated for
    /// rules one and two, which is what they can break.
    ///
    /// The five window controllers are exempt for the same reason: since the
    /// window's ground moved into `EscClosableWindow`, none of them names a role.
    /// They are gated for rules one and two and for the window-ground rule —
    /// which are exactly the rules a controller can break, by painting a system
    /// colour or setting a second, competing ground.
    ///
    /// `SourceViewerContent.swift` is exempt on the same footing: its one colour
    /// was the pane's ground, which now comes from `CodePaneGround` in
    /// `DiffView.swift`. It is gated for rules one and two and for the code-pane
    /// ground rule — a second, private ground being the regression it can commit.
    ///
    /// `LSPInstalledLicenses.swift` is exempt on `ChromeThemeEnvironment.swift`'s
    /// footing: it is a Foundation-only enum that returns the installed licence
    /// documents and has no view, so it paints nothing and names no role by
    /// construction. It is gated for rules one and two, which are the rules it
    /// could break — a system colour or a hex literal creeping into it.
    private static let roleNamingExemptions: Set<String> = [
        "ChromeThemeEnvironment.swift",
        "LSPInstalledLicenses.swift",
        "CommitGraphView.swift",
        "DiffWindowController.swift",
        "MergeWindowController.swift",
        "SourceViewerWindowController.swift",
        "LocalHistoryWindowController.swift",
        "ProjectSearchWindowController.swift",
        "SourceViewerContent.swift",
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
        25: "twenty-five", 26: "twenty-six", 27: "twenty-seven",
        28: "twenty-eight", 29: "twenty-nine", 30: "thirty", 31: "thirty-one",
        32: "thirty-two", 33: "thirty-three", 34: "thirty-four", 35: "thirty-five",
        36: "thirty-six", 37: "thirty-seven", 38: "thirty-eight", 39: "thirty-nine",
        40: "forty", 41: "forty-one",
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

    /// The suite's own header is the rule inventory `CLAUDE.md` sends readers
    /// to, and it drifted — ending at rule thirty-four after thirty-five was
    /// declared — precisely because nothing read it while both documents were
    /// checked. One bolded bullet per rule, between the inventory's opening
    /// sentence and the class declaration, **titled as its marker is and in the
    /// markers' order**: the two ordered lists of titles are compared whole, so a
    /// swapped pair, a dropped rule's bullet or a bullet for a rule that no longer
    /// exists each fails, where a count alone passes all three. Both sides are
    /// normalized the same way — lower-cased, backticks and a trailing full stop
    /// dropped — and nothing else: a marker and its bullet are worded alike.
    func testTheSuitesHeaderInventoriesEveryRule() throws {
        let source = try Self.read(URL(fileURLWithPath: #filePath))
        let opening = try XCTUnwrap(
            source.range(of: "/// What is checked, and why each rule is invisible to the compiler:"),
            "the header inventory's opening sentence is gone — re-point this check rather than losing it"
        )
        let rest = source[opening.upperBound...]
        let end = try XCTUnwrap(
            rest.range(of: "\nfinal class ChromeThemeSourceGatingTests"),
            "the class declaration after the header inventory is gone — re-point this check"
        )
        func normalized(_ title: Substring) -> String {
            var title = title.lowercased().replacingOccurrences(of: "`", with: "")
            if title.hasSuffix(".") { title.removeLast() }
            return title.trimmingCharacters(in: .whitespaces)
        }
        let bullets = rest[..<end.lowerBound]
            .split(separator: "\n")
            .filter { $0.hasPrefix("/// - **") }
            .compactMap { line -> String? in
                let body = line.dropFirst("/// - **".count)
                guard let close = body.range(of: "**") else { return nil }
                return normalized(body[..<close.lowerBound])
            }
        let markers = try NSRegularExpression(pattern: "(?m)^\\s*// MARK: - Rule [a-z-]+: (.+)$")
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let titles = markers.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { normalized(source[$0]) }
        }
        XCTAssertEqual(titles.count, try Self.declaredRuleCount(), "the marker titles must be read whole")
        XCTAssertEqual(
            bullets, titles,
            """
            the suite's header must carry one bolded bullet per declared rule (\(titles.count)), titled as \
            that rule's marker and in the markers' order
            """
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

    /// The canonical list's file sets must be the sets the suite holds: rule
    /// twenty-six's shared-field callers and rule eleven's header-builder files
    /// both drifted from the prose when part five (b) changed the suite, and the
    /// entry a reader consults went on describing the old set. Each passage is
    /// bounded by a start and an end phrase, and every `X.swift` it spells counts
    /// as named; `omitting` removes a file the passage deliberately leaves out.
    ///
    /// Reach, stated so nobody assumes it is total: covered are rule
    /// twenty-six's set (canonical entry and the shared field's `Callers:`
    /// paragraph, which leaves out the defining file) and rule eleven's
    /// header-builder files. Rule thirty-one's pane-ground callers have their own
    /// check above. Every other pinned set the canonical list enumerates — the
    /// gated files, the exemptions, the root lists, rule eleven's whole-file
    /// form, and the rest — is not yet checked against its prose.
    private struct FileSetPassage {
        let label: String
        let start: String
        let end: String
        let expected: Set<String>
        var omitting: Set<String> = []
    }

    private static let canonicalFileSetPassages = [
        FileSetPassage(
            label: "rule twenty-six's shared-field set",
            start: "constructing the shared field or box equals",
            end: "where the box is composed",
            expected: sharedFieldConstructors
        ),
        FileSetPassage(
            label: "the shared field's Callers: paragraph",
            start: "`Toggle`. Callers:",
            end: "The Log bar's doc comment",
            expected: sharedFieldConstructors,
            omitting: ["ChromeControls.swift"]
        ),
        FileSetPassage(
            label: "rule eleven's header-builder files",
            start: "The rule's files are therefore",
            end: "What the counted form",
            expected: Set(headerBuilderFiles.map(\.file))
        ),
    ]

    func testTheCanonicalListsFileSetsAreTheSuitesOwn() throws {
        let theme = try Self.read(Self.document("docs/architecture/core-theme.md"))
        let fileName = try NSRegularExpression(pattern: "[A-Za-z0-9_]+\\.swift")
        for passage in Self.canonicalFileSetPassages {
            let start = try XCTUnwrap(
                theme.range(of: passage.start),
                "core-theme.md no longer opens \(passage.label) with \(passage.start) — re-point this check"
            )
            let rest = theme[start.upperBound...]
            let end = try XCTUnwrap(
                rest.range(of: passage.end),
                "core-theme.md's \(passage.label) no longer ends at \(passage.end) — re-point this check"
            )
            let text = String(rest[..<end.lowerBound])
            let named = Set(
                fileName.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    Range(match.range, in: text).map { String(text[$0]) }
                }
            )
            XCTAssertEqual(
                named, passage.expected.subtracting(passage.omitting),
                "core-theme.md's \(passage.label) must name exactly the files the suite holds"
            )
        }
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
