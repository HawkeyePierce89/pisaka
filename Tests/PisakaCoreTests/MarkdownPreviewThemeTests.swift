import XCTest
@testable import PisakaCore

/// The preview's colour vocabulary: the theme's fields and the highlight-scope
/// table that keys into it.
///
/// Both halves fail *silently* in the product, which is why they are pinned
/// statically here. A theme missing a token kind emits a CSS custom property
/// with no value, and a custom property with no value makes every rule reading it
/// invalid — one absent kind strips the colour off unrelated tokens rather than
/// off its own. A scope missing from the table renders in body-text colour, which
/// is exactly what unhighlighted code already looks like. Neither is visible to a
/// launch, a build, or a reader glancing at the pane.
final class MarkdownPreviewThemeTests: XCTestCase {

    // MARK: - The scope table, both ways

    /// Every scope the pinned standard build emits has a kind, and the table
    /// invents none: set equality, so an entry added to one side alone fails.
    func testEveryPinnedScopeMapsToAKindAndTheTableInventsNone() {
        XCTAssertEqual(
            Set(MarkdownHighlightClasses.scopeKinds.keys),
            MarkdownHighlightClasses.standardScopes
        )
    }

    /// Every token kind is reachable from at least one scope — the other
    /// direction, and the one that catches a *new* kind: a colour the preview
    /// computes and ships in the page's CSS but that no fenced block can ever be
    /// drawn in is a colour nobody chose on purpose.
    func testEveryTokenKindIsReachableFromSomeScope() {
        XCTAssertEqual(
            Set(MarkdownHighlightClasses.scopeKinds.values),
            Set(SyntaxTokenKind.allCases)
        )
    }

    /// The two scopes whose right answer is not the obvious one, pinned by name
    /// so a well-meant "fix" has to argue with a test: an interpolation wrapper
    /// is deliberately uncoloured, and a doctag stays the colour of the comment
    /// it sits inside.
    func testTheTwoDeliberateScopeAnswersArePinned() {
        XCTAssertEqual(MarkdownHighlightClasses.kind(forScope: "subst"), .plain)
        XCTAssertEqual(MarkdownHighlightClasses.kind(forScope: "doctag"), .comment)
    }

    /// The scopes shared with the editor's own capture table resolve to the same
    /// kind on both sides. This is the property the whole file exists for: the
    /// preview and the text view beside it must agree about what a tag, an
    /// attribute, a heading, a code span and a link look like.
    func testSharedScopesAgreeWithTheEditorsCaptureTable() {
        for name in ["tag", "attribute", "comment", "keyword", "string", "number", "type"] {
            XCTAssertEqual(
                MarkdownHighlightClasses.kind(forScope: name),
                SyntaxTokenKind(captureName: name),
                "scope \(name) disagrees with the editor"
            )
        }
        XCTAssertEqual(
            MarkdownHighlightClasses.kind(forScope: "section"),
            SyntaxTokenKind(captureName: "text.title")
        )
        XCTAssertEqual(
            MarkdownHighlightClasses.kind(forScope: "code"),
            SyntaxTokenKind(captureName: "text.literal")
        )
        XCTAssertEqual(
            MarkdownHighlightClasses.kind(forScope: "link"),
            SyntaxTokenKind(captureName: "text.uri")
        )
        XCTAssertEqual(
            MarkdownHighlightClasses.kind(forScope: "emphasis"),
            SyntaxTokenKind(captureName: "text.emphasis")
        )
    }

    func testAnUnknownScopeAnswersNilRatherThanPlain() {
        XCTAssertNil(MarkdownHighlightClasses.kind(forScope: "not-a-scope"))
        XCTAssertNil(MarkdownHighlightClasses.kind(forScope: ""))
    }

    // MARK: - The selector rule

    /// The emission rule: `hljs-` on the first segment, one trailing underscore
    /// per level of depth on each one after it, every class on the same element.
    func testSelectorSpellsTheEmittedClassesAtEveryDepth() {
        XCTAssertEqual(MarkdownHighlightClasses.cssSelector(forScope: "keyword"), ".hljs-keyword")
        XCTAssertEqual(
            MarkdownHighlightClasses.cssSelector(forScope: "char.escape"),
            ".hljs-char.escape_"
        )
        XCTAssertEqual(
            MarkdownHighlightClasses.cssSelector(forScope: "title.function.invoke"),
            ".hljs-title.function_.invoke__"
        )
        XCTAssertEqual(
            MarkdownHighlightClasses.cssSelector(forScope: "title.class.inherited"),
            ".hljs-title.class_.inherited__"
        )
        XCTAssertEqual(
            MarkdownHighlightClasses.cssSelector(forScope: "selector-pseudo"),
            ".hljs-selector-pseudo"
        )
    }

    /// A refinement's selector names strictly more classes than its parent's, so
    /// it wins on specificity wherever both match and the generated stylesheet
    /// needs no ordering to be correct.
    func testARefinementOutweighsItsParent() {
        let parent = MarkdownHighlightClasses.cssSelector(forScope: "title") ?? ""
        let refined = MarkdownHighlightClasses.cssSelector(forScope: "title.function") ?? ""
        XCTAssertTrue(refined.hasPrefix(parent))
        XCTAssertGreaterThan(
            refined.filter { $0 == "." }.count,
            parent.filter { $0 == "." }.count
        )
    }

    func testAnEmptyOrMalformedScopeHasNoSelector() {
        XCTAssertNil(MarkdownHighlightClasses.cssSelector(forScope: ""))
        XCTAssertNil(MarkdownHighlightClasses.cssSelector(forScope: ".escape"))
        XCTAssertNil(MarkdownHighlightClasses.cssSelector(forScope: "title."))
    }

    /// Every pinned scope has a selector — the stylesheet is generated by walking
    /// the table, so a scope the rule cannot spell would be one silently dropped.
    func testEveryPinnedScopeHasASelector() {
        for scope in MarkdownHighlightClasses.standardScopes {
            XCTAssertNotNil(
                MarkdownHighlightClasses.cssSelector(forScope: scope),
                "no selector for \(scope)"
            )
        }
    }

    // MARK: - The theme

    /// Both shipped themes carry a colour for every kind, so `color(for:)` never
    /// reaches its fallback in the product.
    func testBothThemesAreTotalOverTokenKinds() {
        for theme in [MarkdownPreviewTheme.light, .dark] {
            XCTAssertEqual(Set(theme.codeColors.keys), Set(SyntaxTokenKind.allCases))
        }
    }

    /// Both restated code tables are non-empty, total, and written in the one
    /// shape the page can emit: `#` and six lowercase hex digits.
    ///
    /// The restatement exists so the domain layer has a complete theme to test
    /// and fall back on — the app overwrites it from the editor's table at run
    /// time — so nothing in the product reads these strings back and no compiler
    /// can see one drift into a shape the stylesheet cannot use. A value with an
    /// uppercase digit, a three-digit short form or a stray name would be emitted
    /// verbatim into a custom property; this is what refuses it.
    func testBothCodeTablesAreTotalAndWrittenAsLowercaseSixDigitHex() {
        for (name, theme) in [("light", MarkdownPreviewTheme.light), ("dark", .dark)] {
            XCTAssertFalse(theme.codeColors.isEmpty, "\(name) carries no code colours")
            XCTAssertEqual(
                Set(theme.codeColors.keys),
                Set(SyntaxTokenKind.allCases),
                "\(name) is not total over the token kinds"
            )
            for kind in SyntaxTokenKind.allCases {
                let value = theme.codeColors[kind] ?? ""
                XCTAssertNotNil(
                    value.range(of: "^#[0-9a-f]{6}$", options: .regularExpression),
                    "\(name).\(kind) is \(value), not #rrggbb in lowercase hex"
                )
            }
        }
    }

    /// Light and dark differ in *every* field, chrome and code alike — a field
    /// copied from one to the other is a colour that will be unreadable in one of
    /// the two appearances, and only a total comparison catches it.
    func testLightAndDarkDifferInEveryColourField() {
        let light = MarkdownPreviewTheme.light
        let dark = MarkdownPreviewTheme.dark

        for field in DocumentPageChrome.Field.allCases {
            XCTAssertNotEqual(light.chrome[field], dark.chrome[field], "\(field) is the same in both appearances")
        }

        for kind in SyntaxTokenKind.allCases {
            XCTAssertNotEqual(
                light.color(for: kind),
                dark.color(for: kind),
                "\(kind) is the same colour in both appearances"
            )
        }
    }

    /// The theme has exactly one line colour: the table grid and the rule both
    /// read `chrome.border`, and the page emits no second line property.
    ///
    /// This replaces a test that pinned a separate table-grid colour distinct
    /// from `border`, on the reasoning that a table draws a grid of them and
    /// collapsing the two would lose the distinction without anything else
    /// changing. The collapse is deliberate, and this is the answer to that
    /// reason:
    ///
    /// 1. **The closed vocabulary requires it; it is not a preference.** The
    ///    chrome names exactly one line colour, `hairline`, and no role for a
    ///    stronger separator, so a served page may not draw a line stronger than
    ///    the one every other swept surface draws.
    /// 2. **The measured cost.** Dark: the table grid goes from `#4a4a4e` on a
    ///    `#1e1e1e` page to `#393b40` on a `#2f3136` page — a strong grid becomes
    ///    exactly as subtle as every other hairline in the app. Light: from
    ///    `#c7c7cc` on white to `#d1d1d6` on white.
    /// 3. **This is the one place the collapse is felt.** A code block's ground
    ///    may be subtle because it is a large filled area; a one-pixel line may
    ///    not. So the code ground moving is invisible and the rule line moving is
    ///    not.
    /// 4. **The remedy, if it reads badly on screen,** is a change to `hairline`
    ///    itself, which moves every swept surface — never a page-local override
    ///    and never a twenty-second role.
    func testTheThemeHasExactlyOneLineColour() {
        for theme in [MarkdownPreviewTheme.light, .dark] {
            XCTAssertEqual(DocumentPageChrome.role(for: .border), .hairline)
            let page = MarkdownPreviewPage.html(theme: theme, fontSize: 13)
            XCTAssertTrue(page.contains("--border: \(theme.chrome.border);"))
            XCTAssertFalse(page.contains("--table-border"))
            let lineProperties = page.components(separatedBy: "\n").filter {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
                    && $0.contains("border")
            }
            XCTAssertEqual(lineProperties, ["  --border: \(theme.chrome.border);"])
        }
    }

    /// `colorScheme` is a CSS keyword, not a label: anything else and the web
    /// view's own scrollbars and the task-item checkboxes stay light inside a
    /// dark pane.
    func testColorSchemeIsExactlyTheCSSKeyword() {
        XCTAssertEqual(MarkdownPreviewTheme.light.chrome.colorScheme, "light")
        XCTAssertEqual(MarkdownPreviewTheme.dark.chrome.colorScheme, "dark")
    }

    func testResolvedFollowsThePreferenceAndTheSystemAnswer() {
        XCTAssertEqual(MarkdownPreviewTheme.resolved(.light, systemPrefersDark: true), .light)
        XCTAssertEqual(MarkdownPreviewTheme.resolved(.dark, systemPrefersDark: false), .dark)
        XCTAssertEqual(MarkdownPreviewTheme.resolved(.system, systemPrefersDark: true), .dark)
        XCTAssertEqual(MarkdownPreviewTheme.resolved(.system, systemPrefersDark: false), .light)
    }

    /// The fallback is body text, and it is reachable only for a theme built by
    /// hand with a gap in it.
    func testAMissingKindFallsBackToBodyText() {
        let partial = MarkdownPreviewTheme.light.withCodeColors([.keyword: "#ff0000"])
        XCTAssertEqual(partial.color(for: .keyword), "#ff0000")
        XCTAssertEqual(partial.color(for: .comment), MarkdownPreviewTheme.light.chrome.text)
    }

    /// The app's one use of the copy member: the editor's resolved palette
    /// replaces the code colours and every chrome field survives untouched, so a
    /// chrome colour added later cannot silently drop out of the app's theme.
    func testWithCodeColoursKeepsEveryChromeField() {
        let base = MarkdownPreviewTheme.dark
        let copy = base.withCodeColors([.keyword: "#123456"])

        XCTAssertEqual(copy.chrome, base.chrome)
        XCTAssertEqual(copy.codeColors, [.keyword: "#123456"])
    }

    /// The chrome counterpart: the palette's derived value replaces every chrome
    /// field wholesale and the code colours survive untouched.
    func testWithChromeReplacesEveryChromeFieldAndKeepsTheCodeColours() {
        let base = MarkdownPreviewTheme.dark
        let chrome = DocumentPageChrome(
            background: "#010203",
            text: "#040506",
            secondaryText: "#070809",
            link: "#0a0b0c",
            codeBackground: "#0d0e0f",
            border: "#101112",
            colorScheme: "light"
        )
        let copy = base.withChrome(chrome)

        XCTAssertEqual(copy.chrome, chrome)
        for field in DocumentPageChrome.Field.allCases {
            XCTAssertNotEqual(copy.chrome[field], base.chrome[field], "\(field) was not replaced")
        }
        XCTAssertNotEqual(copy.chrome.colorScheme, base.chrome.colorScheme)
        XCTAssertEqual(copy.codeColors, base.codeColors)
    }

    /// The preview's restated chrome is the shared value itself, so the theme
    /// spells no chrome literal of its own.
    func testBothThemesCarryTheSharedChrome() {
        XCTAssertEqual(MarkdownPreviewTheme.light.chrome, DocumentPageChrome.light)
        XCTAssertEqual(MarkdownPreviewTheme.dark.chrome, DocumentPageChrome.dark)
    }

    // MARK: - The custom-property names

    /// One property name per kind, all distinct: two kinds sharing a name would
    /// have the second silently overwrite the first in the generated `:root`
    /// block.
    func testEveryKindHasItsOwnCustomPropertyName() {
        let names = SyntaxTokenKind.allCases.map(MarkdownPreviewTheme.cssVariableName(for:))
        XCTAssertEqual(Set(names).count, SyntaxTokenKind.allCases.count)
        for name in names {
            XCTAssertTrue(name.hasPrefix("--code-"), "\(name) is not in the preview's namespace")
        }
    }

    /// The names are stable strings rather than a derivation from the case names,
    /// which is what makes a Swift rename safe: spot-check the spelling the
    /// stylesheet depends on.
    func testCustomPropertyNamesAreTheSpellingsTheStylesheetUses() {
        XCTAssertEqual(MarkdownPreviewTheme.cssVariableName(for: .keyword), "--code-keyword")
        XCTAssertEqual(MarkdownPreviewTheme.cssVariableName(for: .operator), "--code-operator")
        XCTAssertEqual(MarkdownPreviewTheme.cssVariableName(for: .plain), "--code-plain")
    }
}
