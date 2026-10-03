import XCTest

/// Static verification that no `draw(_:)` override in the app layer fills the
/// rect it is handed.
///
/// A repository-file suite in the `BottomPanelSourceGatingTests` mould: it
/// reads every `.swift` file under `Sources/Pisaka/` — recursively, `iOS/`
/// included — through `#filePath` with Foundation only, and reuses
/// `LSPSourceGatingTests`'s Swift scanner, so **comments and string literals
/// are stripped before anything is matched**. `DiffView.swift` states the very
/// call this rule bans in the comment beside its fix, so a raw `contains`
/// would fail on the comment and pass on a revert written without one.
///
/// What is checked, and why:
///
/// - **A draw override never fills its own parameter.** Since macOS 14
///   `NSView.clipsToBounds` defaults to `false`, so the rect passed to
///   `draw(_:)` is not limited to the view's bounds. `DiffDividerView` filled
///   it, and painted `hairline` over every view beneath it in z-order: with a
///   modified file selected, the Local Changes panel's list and header, the
///   separate diff window's whole left pane and Local History's diff all went
///   blank. Every frame was correct throughout — the accessibility tree read
///   the same before and after — so nothing that measures layout could see
///   it; `LocalChangesLayoutTests` renders it. For every
///   `override func draw(_ <name>: NSRect)` or `… CGRect)`, the body (taken by
///   brace matching, whitespace removed) must not contain `<name>.fill(`,
///   `fill(<name>` — which covers `context.fill(<name>)` and
///   `__NSRectFill(<name>)` — `NSRectFill(<name>`,
///   `NSRectFillUsingOperation(<name>`, `UIRectFill(<name>`, or
///   `NSBezierPath(rect:<name>).fill(` / `UIBezierPath(rect:<name>).fill(`,
///   each with `<name>` as a whole word. A path built on the parameter for
///   anything but a fill (`addClip()`) is not a fill and passes.
/// - **The audit, recorded.** The six overrides beside `DiffDividerView` are
///   clean: `MinimapView` fills `bounds`; `CompletionPanel` fills per-row
///   rects built from `bounds.width` and uses its dirty rect only in
///   `intersects`; `CommitGraphView` strokes lines from `bounds` and fills no
///   dirty rect; the iOS `CommitGraphView_iOS`, `DiffView_iOS` and
///   `MergeView_iOS` do not fill their `rect` (`MergeView_iOS` passes it only
///   to `glyphRange(forBoundingRect:in:)`).
/// - **The set of files declaring a draw override is pinned by set
///   equality**, so a new override is added here — and so reviewed against the
///   rule — deliberately: `DiffView.swift`, `MinimapView.swift`,
///   `CompletionPanel.swift`, `CommitGraphView.swift`,
///   `iOS/CommitGraphView_iOS.swift`, `iOS/DiffView_iOS.swift`,
///   `iOS/MergeView_iOS.swift`.
///
/// **The horizon.** A dirty rect copied into a local and filled through it
/// (`let r = dirtyRect; r.fill()`) passes, and is not chased: the rule reads
/// spellings, not data flow. `testTheRuleCatchesEachSpelling` pins that the
/// spellings it does read are caught.
final class DrawDirtyRectSourceGatingTests: XCTestCase {

    /// The files under `Sources/Pisaka/` that declare a `draw(_:)` override,
    /// relative to that directory.
    private static let drawOverrideFiles: Set<String> = [
        "DiffView.swift",
        "MinimapView.swift",
        "CompletionPanel.swift",
        "CommitGraphView.swift",
        "iOS/CommitGraphView_iOS.swift",
        "iOS/DiffView_iOS.swift",
        "iOS/MergeView_iOS.swift",
    ]

    func testTheDrawOverridesAreThePinnedSet() throws {
        let declaring = try Self.appSources().filter { !Self.drawOverrides(in: $0.code).isEmpty }.map(\.path)
        XCTAssertEqual(
            Set(declaring), Self.drawOverrideFiles,
            "the files declaring a draw(_:) override changed — review the new one against the rule, then pin it"
        )
    }

    func testNoDrawOverrideFillsItsOwnRect() throws {
        var checked = 0
        for source in try Self.appSources() {
            for override in Self.drawOverrides(in: source.code) {
                checked += 1
                XCTAssertNil(
                    Self.fillOfParameter(override),
                    "\(source.path)'s draw(_:) fills its own `\(override.parameter)` — fill `bounds` or a rect built from it"
                )
            }
        }
        XCTAssertEqual(checked, Self.drawOverrideFiles.count, "one draw(_:) override per pinned file")
    }

    func testTheRuleCatchesEachSpelling() {
        let spellings = [
            "dirtyRect.fill()",
            "context.fill(dirtyRect)",
            "__NSRectFill(dirtyRect)",
            "NSRectFill(dirtyRect)",
            "dirtyRect . fill ( )",
            "NSRectFillUsingOperation(dirtyRect, .sourceOver)",
            "UIRectFill(dirtyRect)",
            "NSBezierPath(rect: dirtyRect).fill()",
            "UIBezierPath(rect: dirtyRect).fill()",
        ]
        for body in spellings {
            let code = "override func draw(_ dirtyRect: NSRect) {\n    \(body)\n}"
            let overrides = Self.drawOverrides(in: code)
            XCTAssertEqual(overrides.count, 1, "the override in `\(body)` was not found")
            XCTAssertNotNil(overrides.first.flatMap(Self.fillOfParameter), "`\(body)` passed the rule")
        }
        let clean = """
            override func draw(_ rect: CGRect) {
                bounds.fill()
                context.fill(rectangle)
                NSBezierPath(rect: rect).addClip()
                UIRectFill(rectangle)
            }
            """
        XCTAssertNil(Self.drawOverrides(in: clean).first.flatMap(Self.fillOfParameter))
    }

    // MARK: - The scan

    private struct DrawOverride {
        let parameter: String
        /// The body between its braces, whitespace removed.
        let body: String
    }

    /// Every `override func draw(_ <name>: NSRect | CGRect)` in `code`, with its
    /// body taken by brace matching.
    private static func drawOverrides(in code: String) -> [DrawOverride] {
        let pattern = #"override\s+func\s+draw\s*\(\s*_\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:NSRect|CGRect)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = code as NSString
        return regex.matches(in: code, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let parameter = ns.substring(with: match.range(at: 1))
            let open = ns.range(of: "{", range: NSRange(location: match.range.upperBound,
                                                         length: ns.length - match.range.upperBound))
            guard open.location != NSNotFound else { return nil }
            var depth = 0
            var index = open.location
            while index < ns.length {
                let character = ns.character(at: index)
                if character == UInt16(UInt8(ascii: "{")) { depth += 1 }
                if character == UInt16(UInt8(ascii: "}")) {
                    depth -= 1
                    if depth == 0 { break }
                }
                index += 1
            }
            let body = ns.substring(with: NSRange(location: open.location + 1, length: max(0, index - open.location - 1)))
            return DrawOverride(parameter: parameter, body: body.filter { !$0.isWhitespace })
        }
    }

    /// The first banned spelling in `override`'s body, or `nil`.
    private static func fillOfParameter(_ override: DrawOverride) -> String? {
        let name = override.parameter
        let banned = [
            "\(name).fill(", "fill(\(name)", "NSRectFill(\(name)", "NSRectFillUsingOperation(\(name)",
            "UIRectFill(\(name)", "NSBezierPath(rect:\(name)).fill(", "UIBezierPath(rect:\(name)).fill(",
        ]
        for needle in banned {
            // Where `<name>` sits inside the needle; each spells it exactly once.
            guard let nameInNeedle = needle.range(of: name) else { continue }
            let nameOffset = needle.distance(from: needle.startIndex, to: nameInNeedle.lowerBound)
            var searchStart = override.body.startIndex
            while let found = override.body.range(of: needle, range: searchStart..<override.body.endIndex) {
                // `<name>` must be a whole word on both sides.
                let nameStart = override.body.index(found.lowerBound, offsetBy: nameOffset)
                let nameRange = nameStart..<override.body.index(nameStart, offsetBy: name.count)
                let before = nameRange.lowerBound > override.body.startIndex
                    ? override.body[override.body.index(before: nameRange.lowerBound)] : nil
                let after = nameRange.upperBound < override.body.endIndex ? override.body[nameRange.upperBound] : nil
                let isWord = !(before.map(isIdentifierCharacter) ?? false) && !(after.map(isIdentifierCharacter) ?? false)
                if isWord { return needle }
                searchStart = found.upperBound
            }
        }
        return nil
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: - The sources

    private struct AppSource {
        /// Relative to `Sources/Pisaka/`.
        let path: String
        let code: String
    }

    /// Every `.swift` file under `Sources/Pisaka/`, comment- and literal-stripped.
    private static func appSources() throws -> [AppSource] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PisakaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Sources/Pisaka")
            .standardizedFileURL
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var sources: [AppSource] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            sources.append(AppSource(path: path, code: LSPSourceGatingTests.strippingCommentsAndStringLiterals(source)))
        }
        XCTAssertGreaterThan(sources.count, 50, "Sources/Pisaka is unreadable — the walk is broken, not the code")
        return sources
    }
}
