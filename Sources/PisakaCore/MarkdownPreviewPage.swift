import Foundation

/// The Markdown preview's page: its custom scheme, the URLs that scheme
/// addresses, and the document served over it.
///
/// **The page is served, never string-loaded.** The shell HTML is answered by
/// the app's scheme handler and the web view reaches it with an ordinary
/// request, so the document, the four bundled files and every project image
/// share one app-scheme origin. A string-loaded document has a null origin, and
/// a null origin cannot be granted access to anything — every asset would have
/// to be inlined, which for ~3.4 MB of script bundles means re-sending a copy of
/// the whole page every time the shell is composed again.
///
/// **The vocabulary is spelled once, here.** The scheme name, the host, the
/// shell's URL and the two path prefixes are constants of this file and nothing
/// in the app layer may spell any of them: the handler receives a URL and hands
/// it to Core's classifier, the renderer receives a target and hands it to
/// Core's asset rule, and neither builds or parses a preview URL itself. A
/// second spelling would be a second answer to *which origin is this*, and the
/// two halves of the round trip — the URL the renderer puts into the page and
/// the file the handler serves for it — would be free to disagree.
public enum MarkdownPreviewPage {

    /// The custom URL scheme the whole preview lives under.
    ///
    /// Registered on the web view's configuration, so `WKWebView` routes every
    /// request spelling it to the app's handler and nothing else can be reached:
    /// the page's own CSP names this scheme and no network origin at all.
    ///
    /// It must not be a scheme WebKit already knows (`http`, `file`, `about`, …)
    /// — registering one of those traps — and it carries the app's name so a
    /// URL in a crash log or a devtools panel says where it came from.
    public static let scheme = "pisaka-preview"

    /// The one host every preview URL uses.
    ///
    /// Fixed rather than derived from the document, so a document's *path* never
    /// becomes part of the origin: two Markdown tabs are one origin, and
    /// retargeting the web view from one to the other is not a cross-origin
    /// navigation.
    public static let host = "preview"

    /// The shell document's path.
    public static let shellPath = "/index.html"

    /// The path prefix the four bundled files answer under
    /// (`…/assets/preview.css`).
    ///
    /// Distinct from the project-file prefix because the two are served from
    /// different places — the app bundle and the worktree — and because a
    /// project file must never be reachable under a name the shell's own
    /// `<script>` tags spell.
    public static let bundledPathPrefix = "/assets/"

    /// The path prefix a project file answers under, carrying that file's
    /// **project-relative** path (`…/file/docs/diagram.png`).
    ///
    /// Relative, not absolute: the page never learns where the project sits on
    /// disk, and the inverse mapping cannot be handed a path it did not have to
    /// re-check against the root it was given.
    public static let filePathPrefix = "/file/"

    /// The path prefix a target the forward mapping **refused** is emitted
    /// under, carrying that target's own spelling as one opaque, fully
    /// percent-encoded segment.
    ///
    /// It exists because "emit the source's own spelling" is not, on its own, a
    /// refusal. The page's base URL is ``shellURL``, so a *scheme-less* spelling
    /// left verbatim is re-resolved by the web view against `/index.html` — and
    /// any spelling that normalizes to a path under ``filePathPrefix`` (say
    /// `../file/logo.png`, or every relative target at all in an unsaved buffer)
    /// lands back inside the served project-file namespace, naming a *different*
    /// in-project file. Containment is never broken — the inverse re-checks
    /// against the root either way — but the answer is silently the wrong file
    /// rather than the broken image and the refused link this feature states it
    /// is. Reserving a prefix nothing is served under makes the refusal true.
    ///
    /// The spelling is carried percent-encoded down to alphanumerics precisely
    /// so it cannot climb back out: an unencoded `../..` under this prefix would
    /// be normalized away by the web view before the inverse ever saw it, which
    /// is the bug one level deeper.
    public static let unresolvedPathPrefix = "/unresolved/"

    /// The URL the web view loads, and the only document the handler ever serves
    /// as HTML.
    public static let shellURL = URL(string: "\(scheme)://\(host)\(shellPath)")!
}

// MARK: - The bundled files

extension MarkdownPreviewPage {

    /// The stylesheet the shell links, authored in this repository.
    public static let stylesheetFileName = "preview.css"

    /// The bundled syntax highlighter.
    public static let highlightScriptFileName = "highlight.min.js"

    /// The bundled diagram renderer.
    public static let diagramScriptFileName = "mermaid.min.js"

    /// The first-party script defining ``namespace``'s five members.
    public static let previewScriptFileName = "preview.js"

    /// Every file the shell asks for, in the order it asks — the stylesheet
    /// first, then the two third-party scripts, then the script that uses them.
    ///
    /// One list rather than four call sites, because the scheme handler serves
    /// exactly this set and nothing else: a name absent here is a 404, and a name
    /// added here without a file beside it is a script tag that silently does not
    /// load. The order is load order, and it is load-bearing — `preview.js`
    /// touches `hljs` and `mermaid` at boot.
    public static let bundledFileNames: [String] = [
        stylesheetFileName,
        highlightScriptFileName,
        diagramScriptFileName,
        previewScriptFileName,
    ]

    /// The page-relative URL path a bundled file answers under.
    public static func bundledPath(forFileName name: String) -> String {
        bundledPathPrefix + name
    }

    /// The absolute URL string a refused target is emitted as, given that
    /// target's spelling already reduced to one opaque segment.
    ///
    /// Absolute rather than page-relative, so that there is nothing left for the
    /// base URL to do to it — a relative spelling under this prefix would be
    /// resolved, and resolving it is the whole thing this prefix exists to stop.
    /// The composition lives here because the scheme and the host are spelled in
    /// this file and in no other.
    public static func unresolvedURLString(forOpaqueTarget segment: String) -> String {
        "\(scheme)://\(host)\(unresolvedPathPrefix)\(segment)"
    }
}

// MARK: - The document

extension MarkdownPreviewPage {

    /// The `id` of the one element the rendered body is written into.
    ///
    /// The shell ships it empty: the body arrives later, through
    /// ``bodyUpdateSource(body:)``, and never as part of the document — which is
    /// what makes a keystroke an `innerHTML` assignment rather than a page load,
    /// and is why the scroll position survives typing.
    public static let containerElementID = "content"

    /// The prefix every id `preview.js` hands mermaid carries — the second
    /// family of `id`s the page holds that the renderer did not write.
    ///
    /// mermaid is given an id per diagram render and **removes whatever element
    /// already carries it** before it measures its own (`removeExistingElements`
    /// in the bundle), so an id family that a heading slug could also produce
    /// would delete that heading from the page the moment any fence rendered —
    /// silently, and taking its anchor with it. The container id is reserved in
    /// ``MarkdownRenderer`` for the same class of failure; this one cannot be
    /// reserved that way because the sequence has no end, so it is kept out of
    /// reach by its *alphabet* instead.
    ///
    /// An ASCII capital is what does it: ``MarkdownHeadingSlug/slug(forText:)``
    /// lowercases before it filters, so no slug it can ever answer carries one —
    /// which makes "no heading is a diagram id" a property of the two spellings
    /// rather than of anyone remembering. `MarkdownHeadingSlugTests` asserts
    /// both halves, and `MarkdownPreviewAssetPinTests` pins the script's own
    /// spelling of it, the two files being in different languages with nothing
    /// else able to notice a rename on one side.
    ///
    /// The rest of the id is a decimal counter `preview.js` owns, so the whole
    /// id stays a CSS identifier: mermaid builds `#\(id)`, `#d\(id)` and
    /// `#i\(id)` selectors from it, and anything needing an escape there would
    /// throw inside the bundle.
    public static let diagramElementIDPrefix = "PisakaDiagram"

    /// The JavaScript global `preview.js` defines and everything else calls
    /// through. Spelled once so the bootstrap, the body update and the scroll
    /// call cannot name three different objects.
    public static let namespace = "PisakaPreview"

    /// The two custom properties the page draws its text at.
    ///
    /// Named constants rather than literals because they have **three** writers
    /// and readers in two languages: the shell's `:root` block writes them,
    /// `preview.css` reads them, and `preview.js`'s `setFontSize` writes them
    /// again on a size step. A rename spelled in only two of the three leaves
    /// the shell correct and every step silently inert, which is exactly what
    /// `MarkdownPreviewAssetPinTests` exists to refuse.
    public static let bodyFontSizeProperty = "--font-size"

    /// The code face's size — see ``bodyFontSizeProperty``.
    public static let codeFontSizeProperty = "--code-font-size"

    /// The shell's one inline script: the call that starts the page.
    ///
    /// It is inline — not a fifth bundled file — because it is the *document's*
    /// statement about itself rather than a script's, and because a hash in the
    /// CSP can pin one exact line where a file URL can only be trusted. Its bytes
    /// and the hash in ``contentSecurityPolicy`` are derived from this one
    /// constant, so the two cannot disagree: change the line and the hash moves
    /// with it.
    public static let bootstrapSource = "window.\(namespace).boot();"

    /// The CSP source expression pinning ``bootstrapSource`` — `sha256-` and the
    /// base64 digest of the script's exact bytes, which is what CSP hashes.
    public static let bootstrapScriptHash =
        "sha256-" + SHA256.digest(of: Data(bootstrapSource.utf8)).base64EncodedString()

    /// The page's Content Security Policy, emitted as a `<meta http-equiv>`.
    ///
    /// **No network origin appears in it at all**, which is the feature's whole
    /// containment property stated positively: `default-src 'none'` refuses
    /// everything not named below, and nothing below names `http`, `https` or
    /// `*`. A document that cannot reach the network cannot leak the contents of
    /// the file it is previewing, whatever a `<script>` in the source might have
    /// wished — and the tree carries no raw HTML to begin with, so this is the
    /// second of two independent reasons rather than the only one.
    ///
    /// Term by term:
    ///
    /// * `script-src` names the app scheme and one **hash**. Never
    ///   `'unsafe-inline'`: the hash pins the single bootstrap line by its bytes,
    ///   and any *other* inline script — one an author wrote, one an injection
    ///   produced — fails to match and does not run.
    /// * `style-src` names the app scheme and `'unsafe-inline'`, which is the
    ///   one relaxation here and it is forced: the diagram renderer emits its
    ///   `<style>` element into the SVG it builds, so a page that refuses inline
    ///   styles renders every diagram unstyled. Styles cannot exfiltrate over a
    ///   `connect-src 'none'`/`img-src` without a network origin, which is why
    ///   this is the cheap relaxation to make and `script-src`'s is not.
    /// * `img-src` adds `data:` for the same diagram renderer, which inlines
    ///   raster fallbacks; project images arrive under the app scheme.
    /// * `connect-src 'none'` is redundant with `default-src` and stated anyway,
    ///   because it is the clause a reader looks for.
    /// * `base-uri 'none'` and `form-action 'none'` close the two ways a document
    ///   can re-point or post itself elsewhere without fetching anything.
    public static let contentSecurityPolicy = [
        "default-src 'none'",
        "script-src \(scheme): '\(bootstrapScriptHash)'",
        "style-src \(scheme): 'unsafe-inline'",
        "img-src \(scheme): data:",
        "connect-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
    ].joined(separator: "; ")

    /// The whole shell document: everything the page is before a body arrives.
    ///
    /// A pure function of the theme and the code font size. The theme is the
    /// only one of the two a change in which re-writes it: a size is also
    /// settable on a loaded page through ``fontSizeUpdateSource(fontSize:)``,
    /// and is embedded here so that a shell composed later says what the page
    /// was already showing. Everything else about the page (the document being
    /// previewed, its text, its scroll position) reaches it through JavaScript
    /// instead, which is why typing does not reload.
    public static func html(theme: MarkdownPreviewTheme, fontSize: Double) -> String {
        """
            <!DOCTYPE html>
            <html lang="en" data-color-scheme="\(theme.colorScheme)">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
            <title>Preview</title>
            <link rel="stylesheet" href="\(bundledPath(forFileName: stylesheetFileName))">
            <style>
            \(themeStylesheet(theme: theme, fontSize: fontSize))
            </style>
            </head>
            <body>
            <div id="\(containerElementID)"></div>
            <script src="\(bundledPath(forFileName: highlightScriptFileName))"></script>
            <script src="\(bundledPath(forFileName: diagramScriptFileName))"></script>
            <script src="\(bundledPath(forFileName: previewScriptFileName))"></script>
            <script>\(bootstrapSource)</script>
            </body>
            </html>
            """
    }

    /// The theme, as CSS.
    ///
    /// Two halves, and both are *generated*: the custom properties every rule in
    /// `preview.css` reads, and one colour rule per highlight scope, emitted by
    /// walking ``MarkdownHighlightClasses``. The second half is why the class
    /// table is a table rather than a hand-written stylesheet — a scope added
    /// there gets its rule here for free, and the set-equality tests are what
    /// keep the table honest.
    ///
    /// The `<link>` to `preview.css` precedes this block in the document on
    /// purpose: the theme is what must win, so it is written last.
    private static func themeStylesheet(theme: MarkdownPreviewTheme, fontSize: Double) -> String {
        """
        :root {
        \(customProperties(theme: theme, fontSize: fontSize))
        }
        \(highlightRules(theme: theme))
        """
    }

    /// The two sizes the page draws with, derived from the one number the
    /// window forwards: the clamp, and the code face's one-point offset.
    ///
    /// **One helper rather than two arithmetic sites**, because a size now
    /// reaches the page two ways — embedded in a shell the handler serves, and
    /// set on the document already loaded by
    /// ``fontSizeUpdateSource(fontSize:)`` — and the whole point of the second
    /// is that it means exactly what the first would have. Two spellings of
    /// "a point smaller" would be a preview whose code font changed size when
    /// the theme did.
    ///
    /// The clamp is `SettingsStore`'s, so this is the editor's own zoom zone
    /// read once rather than a second opinion about what a font size may be;
    /// `code` is a point smaller than `body` for the reason the statement panel
    /// states: a monospace face at the editor's own size reads visibly larger
    /// than the proportional text beside it.
    static func fontSizes(for fontSize: Double) -> (body: Double, code: Double) {
        let body = SettingsStore.clampFontSize(fontSize)
        return (body: body, code: body - 1)
    }

    /// The custom properties, one declaration per line.
    ///
    /// The chrome names are spelled here and read by `preview.css`; the code
    /// names come from ``MarkdownPreviewTheme/cssVariableName(for:)``, so the
    /// stylesheet and the palette cannot drift. The two sizes are
    /// ``fontSizes(for:)``'s, which is what a font-size step later sets on this
    /// same `:root` from the other side.
    private static func customProperties(theme: MarkdownPreviewTheme, fontSize: Double) -> String {
        let sizes = fontSizes(for: fontSize)
        var lines = [
            "  color-scheme: \(theme.colorScheme);",
            "  --background: \(theme.background);",
            "  --text: \(theme.text);",
            "  --secondary-text: \(theme.secondaryText);",
            "  --link: \(theme.link);",
            "  --code-background: \(theme.codeBackground);",
            "  --border: \(theme.border);",
            "  --table-border: \(theme.tableBorder);",
            "  \(bodyFontSizeProperty): \(css(sizes.body))px;",
            "  \(codeFontSizeProperty): \(css(sizes.code))px;",
        ]
        for kind in SyntaxTokenKind.allCases {
            lines.append("  \(MarkdownPreviewTheme.cssVariableName(for: kind)): \(theme.color(for: kind));")
        }
        return lines.joined(separator: "\n")
    }

    /// One rule per highlight scope, in a stable order.
    ///
    /// Sorted by scope name for a readable, diffable document — never for
    /// precedence: a refined scope's selector names more classes than its
    /// parent's, so specificity settles which rule wins and no ordering is
    /// relied on (``MarkdownHighlightClasses/cssSelector(forScope:)``).
    private static func highlightRules(theme: MarkdownPreviewTheme) -> String {
        MarkdownHighlightClasses.standardScopes.sorted().compactMap { scope in
            guard
                let selector = MarkdownHighlightClasses.cssSelector(forScope: scope),
                let kind = MarkdownHighlightClasses.kind(forScope: scope)
            else { return nil }
            return "\(selector) { color: var(\(MarkdownPreviewTheme.cssVariableName(for: kind))); }"
        }
        .joined(separator: "\n")
    }

    /// A point value as CSS, trimming the trailing `.0` an integral size would
    /// otherwise carry. `LeetCodeStatementDocument`'s rule, for the same reason:
    /// `13px` is what a stylesheet says.
    private static func css(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - The entry points

extension MarkdownPreviewPage {

    /// The JavaScript that replaces the page's body with `body` and re-runs the
    /// highlighter and the diagram renderer over it.
    ///
    /// The app evaluates this string and composes none of it. `body` crosses as a
    /// **value** — a JavaScript string literal this file escapes — never as a
    /// fragment spliced into source, so a document containing a quote, a
    /// backslash, a newline or the characters `</script>` produces a call with
    /// one argument rather than a syntax error or a second statement. The markup
    /// inside it was already escaped once by `MarkdownRenderer`; this escaping is
    /// about the transport, not about the content.
    public static func bodyUpdateSource(body: String) -> String {
        "window.\(namespace).render(\(javaScriptStringLiteral(body)));"
    }

    /// The JavaScript that scrolls the page to the element a fragment names.
    ///
    /// The argument crosses as a **value**, escaped by the same rule the body
    /// does, because a fragment is author text: it arrives from an `href` in a
    /// document nobody in this app wrote, and a fragment spliced into source
    /// would be a way to end the call and start a statement.
    ///
    /// The page answers this by an `id` lookup and does nothing when it finds
    /// none. What it finds are the heading anchors `MarkdownRenderer` emits
    /// through `MarkdownHeadingSlug` — the whole reading of a heading's text
    /// happens in Core, so this seam carries a name, never a rule — and a
    /// fragment naming nothing in the document leaves the page where it is,
    /// which is the honest answer for a link to a section that is not there. The
    /// seam exists here rather than in the navigation delegate for the reason
    /// every other one does: the app passes a fragment, it does not compose a
    /// call.
    public static func scrollToAnchorSource(anchor: String) -> String {
        "window.\(namespace).scrollToAnchor(\(javaScriptStringLiteral(anchor)));"
    }

    /// The JavaScript that scrolls the page to the last top-level block whose
    /// `data-line` is at or before `line`.
    ///
    /// The argument is an `Int` and is interpolated as one: a number has no
    /// spelling that could end the call and start a statement, which is the whole
    /// reason the scroll line crosses this seam as a number rather than as text.
    /// It is not clamped here — what a valid line is belongs to
    /// `MarkdownScrollRule`, and a page asked for a line it does not have simply
    /// scrolls to the nearest one it does.
    public static func scrollToLineSource(line: Int) -> String {
        "window.\(namespace).scrollToLine(\(line));"
    }

    /// The JavaScript that sets the page's two font sizes on the document
    /// already loaded — the last of the sources composed here, and the reason a
    /// code-zoom step is no longer a page load.
    ///
    /// Both arguments cross as **numbers**, spelled by the same `css(_:)` rule
    /// the shell's `:root` block uses and read out of the one
    /// ``fontSizes(for:)`` helper, so an in-place step and a shell composed a
    /// moment later cannot disagree about what a size is. A number needs no
    /// escaping for the reason the scroll line needs none: there is no spelling
    /// of one that could end the call and start a statement — which is the
    /// safety property the body and the anchor buy with a string literal.
    ///
    /// **Two arguments rather than one**, because the page draws with two sizes
    /// and the second is a point below the first. Sending one and subtracting
    /// there would put an arithmetic decision in `preview.js`, which decides
    /// nothing; the page appends the unit and sets the two properties.
    public static func fontSizeUpdateSource(fontSize: Double) -> String {
        let sizes = fontSizes(for: fontSize)
        return "window.\(namespace).setFontSize(\(css(sizes.body)), \(css(sizes.code)));"
    }

    /// `value` as a JavaScript string literal, quotes included.
    ///
    /// Deliberately stricter than JSON, in the three ways that matter here:
    /// `<` and `>` are escaped, so the literal survives being read inside a
    /// `<script>` element as well as through `evaluateJavaScript`; `&` with them,
    /// so no entity can form; and U+2028/U+2029, which older JavaScript parsers
    /// read as line terminators inside a literal. The output remains valid JSON,
    /// which is what lets a test decode it back and compare.
    static func javaScriptStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - The page seam

/// The page, as the preview's model is allowed to see it: two verbs and no
/// third.
///
/// The model owns *when* — every ordering decision, every token, the debounce —
/// and the page owns nothing at all; this protocol is the line between them.
/// Its production conformer is the app's one web view, and the tests' scripted
/// one records what it was asked to do, which is what lets the whole ordering be
/// asserted in `swift test` with no WebKit present.
///
/// Both verbs carry a string ``MarkdownPreviewPage`` composed — a JavaScript
/// source and a shell document — because the conformer is not allowed to compose
/// either. That is the same rule the parser seam states from the other side: the
/// app layer supplies capability, Core supplies content.
///
/// `@MainActor`, because both verbs end in a `WKWebView` call and the model that
/// makes them is a main-actor model; isolating the seam is what keeps that from
/// being a convention every conformer has to remember.
@MainActor
public protocol MarkdownPreviewPageSink: AnyObject {

    /// Run `source` in the page that is already loaded.
    ///
    /// The body update and both scrolls arrive this way. Nothing is returned:
    /// the page answers no questions, so there is nothing to await and no
    /// failure the model could act on — a source that lands before the document
    /// does is lost, which is exactly what re-serving the shell then re-sending
    /// the body already covers.
    func evaluate(_ source: String)

    /// Install `html` as the shell and load it, replacing whatever the page
    /// held.
    ///
    /// The one navigation the feature performs. It is a *load*, not a string
    /// load: `html` becomes what the app's scheme handler answers for the
    /// shell's URL, and the page is then fetched from that URL, so the document
    /// and every asset share one origin.
    func reloadShell(html: String)
}
