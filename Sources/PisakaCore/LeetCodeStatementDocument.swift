import Foundation

/// The statement panel's whole document, composed here so the web view is thin.
///
/// LeetCode answers `question.content` with an HTML **fragment** — a run of
/// `<p>`, `<pre>`, `<img>` and `<code>` with no `<html>`, no `<head>`, no charset
/// and no stylesheet of its own. Handing that straight to a `WKWebView` produces
/// a page in Times New Roman on white, mojibake for every non-ASCII character in
/// the statement, and broken images (its `<img src>`s are relative to
/// `https://leetcode.com/`). The panel therefore renders a document this type
/// composes, and the platform views on both sides load a `String` rather than
/// each growing their own copy of the same `<head>`.
///
/// **Colours arrive as values.** `Theme` is six strings; nothing here reads
/// `NSColor`, `UIColor` or the system appearance, because Core may not import
/// AppKit/UIKit and because a document that is a pure function of its inputs is
/// one a unit test can assert light and dark differ in. The view layer resolves
/// `ThemePreference.system` against the appearance it is actually running in and
/// passes the answer in — `Theme.resolved(_:systemPrefersDark:)` is that one
/// mapping, kept here so both platforms make it identically.
///
/// **The fragment is never rewritten.** It is interpolated verbatim, including
/// whatever markup LeetCode chose; sanitising it would be a second, silently
/// drifting parser for an unofficial API, and the panel loads no script and
/// grants the document no privileges that would make the markup interesting.
/// Escaping applies only to the *title*, which travels through `<title>` and is a
/// value this app supplies.
public enum LeetCodeStatementDocument {

    /// The handful of colours the statement's CSS needs, as CSS colour strings.
    ///
    /// Six, not a palette: the statement is body text, links, code and a rule.
    /// `colorScheme` is the CSS `color-scheme` keyword — what makes the web
    /// view's own scrollbars and any form control in the markup match rather than
    /// staying stubbornly light inside a dark panel.
    public struct Theme: Equatable, Sendable {
        public let background: String
        public let text: String
        /// Muted text: the difficulty line and anything LeetCode marks up as
        /// secondary.
        public let secondaryText: String
        public let link: String
        /// The fill behind `<code>` and `<pre>` — the example blocks are most of a
        /// LeetCode statement, so this is the colour that decides whether the
        /// panel reads as one surface or two.
        public let codeBackground: String
        public let border: String
        /// `"light"` or `"dark"`, emitted as CSS `color-scheme`.
        public let colorScheme: String

        public init(
            background: String,
            text: String,
            secondaryText: String,
            link: String,
            codeBackground: String,
            border: String,
            colorScheme: String
        ) {
            self.background = background
            self.text = text
            self.secondaryText = secondaryText
            self.link = link
            self.codeBackground = codeBackground
            self.border = border
            self.colorScheme = colorScheme
        }

        public static let light = Theme(
            background: "#ffffff",
            text: "#1d1d1f",
            secondaryText: "#6e6e73",
            link: "#0066cc",
            codeBackground: "#f2f2f7",
            border: "#d2d2d7",
            colorScheme: "light"
        )

        public static let dark = Theme(
            background: "#1e1e1e",
            text: "#e8e8ed",
            secondaryText: "#9a9aa0",
            link: "#6bb3ff",
            codeBackground: "#2a2a2e",
            border: "#3a3a3e",
            colorScheme: "dark"
        )

        /// The theme a preference resolves to in an app that is currently running
        /// light or dark.
        ///
        /// `ThemePreference.system` carries no colour by itself — it means
        /// "whatever the OS says" — so the caller supplies the answer to that
        /// question and this mapping stays total. Both platforms call it, which is
        /// why it is not written twice in the view layer.
        public static func resolved(
            _ preference: ThemePreference,
            systemPrefersDark: Bool
        ) -> Theme {
            switch preference {
            case .light: return .light
            case .dark: return .dark
            case .system: return systemPrefersDark ? .dark : .light
            }
        }
    }

    /// The complete document for one statement.
    ///
    /// `fontSize` is the editor's font size in points, used as the document's
    /// body size so the panel and the code beside it read at one scale. It goes
    /// through `SettingsStore.clampFontSize`, which is what keeps a NaN or an
    /// absurd value out of the CSS — an unparsable `font-size` would silently
    /// drop the whole declaration.
    public static func html(
        fragment: String,
        title: String,
        theme: Theme,
        fontSize: Double
    ) -> String {
        let size = SettingsStore.clampFontSize(fontSize)
        return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <base href="\(LeetCodeAPI.siteURL.absoluteString)">
            <title>\(escaped(title))</title>
            <style>
            \(stylesheet(theme: theme, fontSize: size))
            </style>
            </head>
            <body>
            <div class="statement">
            \(fragment)
            </div>
            </body>
            </html>
            """
    }

    /// The inline stylesheet, split out so `html(fragment:…)` reads as the shape
    /// of the document rather than as a wall of CSS.
    ///
    /// Every colour is interpolated from `theme` and nothing is hard-coded to a
    /// light default, which is the property the light-vs-dark test asserts by
    /// requiring the two documents to differ.
    private static func stylesheet(theme: Theme, fontSize: Double) -> String {
        let bodySize = css(fontSize)
        // Code sits a touch smaller than prose: a monospace face at the editor's
        // own point size renders visibly larger than the proportional body text
        // beside it.
        let codeSize = css(fontSize - 1)
        return """
            :root { color-scheme: \(theme.colorScheme); }
            html { -webkit-text-size-adjust: 100%; }
            body {
              margin: 0;
              padding: 16px 18px 32px;
              background: \(theme.background);
              color: \(theme.text);
              font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
              font-size: \(bodySize)px;
              line-height: 1.55;
              overflow-wrap: break-word;
              word-break: break-word;
            }
            .statement > *:first-child { margin-top: 0; }
            a { color: \(theme.link); }
            img { max-width: 100%; height: auto; }
            code, pre, kbd, samp {
              font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
              font-size: \(codeSize)px;
            }
            code {
              background: \(theme.codeBackground);
              border-radius: 4px;
              padding: 1px 4px;
            }
            pre {
              background: \(theme.codeBackground);
              border-radius: 6px;
              padding: 10px 12px;
              overflow-x: auto;
              white-space: pre-wrap;
            }
            pre code { background: none; padding: 0; }
            hr { border: 0; border-top: 1px solid \(theme.border); margin: 20px 0; }
            blockquote {
              margin: 12px 0;
              padding-left: 12px;
              border-left: 3px solid \(theme.border);
              color: \(theme.secondaryText);
            }
            table { border-collapse: collapse; }
            th, td { border: 1px solid \(theme.border); padding: 4px 8px; }
            strong, b { font-weight: 600; }
            sup { color: \(theme.secondaryText); }
            """
    }

    /// A `Double` as a CSS length: whole numbers without a trailing `.0`, which is
    /// what makes the emitted stylesheet stable enough to assert on.
    private static func css(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// The five characters that may not travel into markup as themselves.
    ///
    /// Only the title goes through here (see the note on the type). `&` is
    /// replaced first, or the ampersands this function itself introduces would be
    /// escaped a second time.
    static func escaped(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        return escaped.replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// The statement half of the on-disk cache: one HTML fragment per slug, stored
/// exactly as LeetCode sent it.
///
/// Its whole purpose is the offline reopen. A solution file outlives the session
/// that created it, and a person on a plane opening yesterday's problem should
/// see the statement they were working from — so the fragment is written beside
/// the catalog and read back whenever the network cannot answer. Images are the
/// one thing that will be missing: they live on LeetCode's CDN and are not
/// mirrored here (a known limit, not an oversight — mirroring them would turn a
/// text cache into an asset store with its own eviction problem).
///
/// **Verbatim in, verbatim out.** What is stored is the fragment, not the
/// composed document: the theme and the font size are session state, and a cache
/// of rendered HTML would be stale the moment the user switched appearance.
/// `LeetCodeStatementDocument.html(fragment:…)` is applied on the way to the web
/// view, every time.
///
/// **Neither half throws.** A read failure is "no cached statement" and a write
/// failure is "this one will be fetched again", exactly as `LeetCodeCatalog`
/// treats its own cache: the user asked to see a problem, and a cache directory
/// that has gone read-only is not a reason to refuse. `store` reports whether it
/// persisted so a test can see the degradation, and every caller is free to
/// ignore it.
public struct LeetCodeStatementCache {
    private let layout: LeetCodeCacheLayout
    private let fileService: FileServicing

    public init(layout: LeetCodeCacheLayout, fileService: FileServicing) {
        self.layout = layout
        self.fileService = fileService
    }

    /// Where `slug`'s fragment is kept, or `nil` when `slug` is not a slug this
    /// app will make a file name out of.
    ///
    /// Forwarded rather than reached for through a public `layout`, so the
    /// sanitising rule — `LeetCodeProblemInput.normalizedSlug(_:)`, the same rule
    /// the input field applies — stays the only way in.
    public func file(forSlug slug: String) -> URL? {
        layout.statementFile(forSlug: slug)
    }

    /// The cached fragment for `slug`, or `nil`.
    ///
    /// One `nil` for four situations — an unusable slug, no file, an unreadable
    /// file, and a file that is empty or blank — because the caller's response to
    /// all four is the same: fetch it. The blank case is not pedantry: a
    /// half-written or truncated cache file is the realistic way an empty one
    /// appears, and returning `""` would render an empty panel *and* suppress the
    /// fetch that would have fixed it.
    public func fragment(forSlug slug: String) -> String? {
        guard let url = layout.statementFile(forSlug: slug),
              let text = try? fileService.read(url: url),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Whether a fragment is cached for `slug` — the same question as
    /// `fragment(forSlug:) != nil`, named for the call sites that only decide
    /// whether a network failure is worth reporting.
    public func hasFragment(forSlug slug: String) -> Bool {
        fragment(forSlug: slug) != nil
    }

    /// Persist `fragment` for `slug`, answering whether it landed.
    ///
    /// Refuses an empty or blank fragment for the same reason
    /// `LeetCodeCatalog.refresh` refuses an empty catalog: a shape-valid nothing
    /// would be served from the cache forever after, and the one thing worse than
    /// no statement is a permanently blank one.
    @discardableResult
    public func store(_ fragment: String, forSlug slug: String) -> Bool {
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = layout.statementFile(forSlug: slug)
        else { return false }
        do {
            try fileService.ensureDirectory(at: layout.statementsDirectory)
            try fileService.write(fragment, to: url)
            return true
        } catch {
            return false
        }
    }
}
