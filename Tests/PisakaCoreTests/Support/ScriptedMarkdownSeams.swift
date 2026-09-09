import Foundation
@testable import PisakaCore

/// The Markdown preview's two seams, scripted: a parser that records what it was
/// asked for and can be *held* mid-parse, and a page that records what it was
/// told to do.
///
/// Together they are what makes `MarkdownPreviewModel`'s whole ordering — the
/// generation token, the debounce, the no-second-parse rule for an appearance
/// change, the once-per-turn scroll flush — assertable in `swift test` with
/// neither `apple/swift-markdown` nor WebKit present.

// MARK: - The parser

/// A `MarkdownParsing` that answers scripted trees and can be blocked.
///
/// Two departures from the house scripted-seam style, both deliberate:
///
/// * **An unscripted text does not fail.** A parser has no failure case —
///   ``MarkdownParsing/parse(_:)`` is total and cannot throw — so an unscripted
///   text answers a document consisting of one paragraph carrying that text
///   verbatim. That is what lets an assertion read *which buffer produced the
///   body on the page*, which is the question every ordering test here is
///   really asking, without a scripted tree per case.
/// * **A gate is per text and is entered on the way in.** ``parsed`` records at
///   entry rather than at return, so two parses can be observed to be in flight
///   at the same time — the staging the superseded-parse test needs.
final class ScriptedMarkdownParser: MarkdownParsing, @unchecked Sendable {

    private let lock = NSLock()
    private var scripted: [String: MarkdownDocument] = [:]
    private var gates: [String: Gate] = [:]
    private var entered: [String] = []
    private var returned: [String] = []

    /// Answer `document` for `text` instead of the default one-paragraph tree.
    func script(_ text: String, as document: MarkdownDocument) {
        lock.lock()
        defer { lock.unlock() }
        scripted[text] = document
    }

    /// Hold the parse of `text` until the returned gate is released.
    @discardableResult
    func hold(_ text: String) -> Gate {
        let gate = Gate()
        lock.lock()
        gates[text] = gate
        lock.unlock()
        return gate
    }

    /// Every text this parser was asked for, in the order it was entered.
    var parsed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    /// Every text whose parse has *returned*, in completion order.
    ///
    /// The counterpart to ``parsed``, and the thing a superseded-parse assertion
    /// must wait on: an assertion that the stale run published nothing is
    /// vacuous while that run is still suspended on its gate.
    var completedParses: [String] {
        lock.lock()
        defer { lock.unlock() }
        return returned
    }

    /// Spin the caller's actor until `text` has been entered, so a test never
    /// stages a second parse before the first one is actually running.
    func waitUntilParsing(_ text: String) async {
        while !parsed.contains(text) { await Task.yield() }
    }

    /// Spin the caller's actor until the parse of `text` has returned.
    func waitUntilParsed(_ text: String) async {
        while !completedParses.contains(text) { await Task.yield() }
    }

    /// The document one paragraph of `text` is, which is what an unscripted text
    /// answers. Exposed so a test can spell the expectation the same way.
    static func defaultDocument(for text: String) -> MarkdownDocument {
        MarkdownDocument(blocks: [MarkdownTopLevelBlock(block: .paragraph([.text(text)]), sourceLine: 1)])
    }

    func parse(_ text: String) -> MarkdownDocument {
        lock.lock()
        entered.append(text)
        let gate = gates[text]
        let document = scripted[text]
        lock.unlock()

        gate?.wait()

        lock.lock()
        returned.append(text)
        lock.unlock()
        return document ?? Self.defaultDocument(for: text)
    }
}

// MARK: - The page

/// A `MarkdownPreviewPageSink` that records, in order, everything the model told
/// the page to do.
///
/// It answers nothing back, because the real seam answers nothing back: the page
/// is written to and never asked. The decoding accessors below read the model's
/// *intent* back out of the JavaScript `MarkdownPreviewPage` composed —
/// deliberately by decoding the argument rather than by matching the source
/// text, so a test asserts the body that reached the page rather than the
/// escaping on the way there.
@MainActor
final class ScriptedMarkdownPageSink: MarkdownPreviewPageSink {

    enum Event: Equatable {
        case evaluate(String)
        case reloadShell(String)
    }

    private(set) var events: [Event] = []

    func evaluate(_ source: String) {
        events.append(.evaluate(source))
    }

    func reloadShell(html: String) {
        events.append(.reloadShell(html))
    }

    /// Every evaluated source, in order.
    var evaluatedSources: [String] {
        events.compactMap { if case .evaluate(let source) = $0 { return source } else { return nil } }
    }

    /// Every shell document installed, in order.
    var shellReloads: [String] {
        events.compactMap { if case .reloadShell(let html) = $0 { return html } else { return nil } }
    }

    /// The body of every `render` call, decoded from its argument.
    var bodies: [String] {
        evaluatedSources.compactMap { Self.argument(of: $0, calling: "render").flatMap(Self.decodedString(_:)) }
    }

    /// The line of every `scrollToLine` call.
    var scrolledLines: [Int] {
        evaluatedSources.compactMap { Self.argument(of: $0, calling: "scrollToLine").flatMap(Int.init) }
    }

    /// The anchor of every `scrollToAnchor` call, decoded from its argument.
    var scrolledAnchors: [String] {
        evaluatedSources.compactMap {
            Self.argument(of: $0, calling: "scrollToAnchor").flatMap(Self.decodedString(_:))
        }
    }

    func clearEvents() {
        events.removeAll()
    }

    /// The single argument of `window.PisakaPreview.<member>(…);`, or `nil` when
    /// the source is a call to something else.
    private static func argument(of source: String, calling member: String) -> String? {
        let prefix = "window.\(MarkdownPreviewPage.namespace).\(member)("
        let suffix = ");"
        guard source.hasPrefix(prefix), source.hasSuffix(suffix) else { return nil }
        return String(source.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// A JavaScript string literal, read back as the string it carries.
    ///
    /// `MarkdownPreviewPage.javaScriptStringLiteral(_:)` is deliberately valid
    /// JSON, which is what lets this be a decode rather than a second, mirrored
    /// unescaping that could agree with a bug.
    private static func decodedString(_ literal: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }
}
