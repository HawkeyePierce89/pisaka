#if os(macOS) || os(iOS)
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Neon
import RangeState
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitterClient

/// The one syntax highlighter every code view attaches: Neon's
/// `TextViewHighlighter`, rebuilt from Neon's public pieces so that **every**
/// highlight request resolves the query's predicates.
///
/// The pinned Neon answers a highlight request two ways. Its asynchronous half
/// runs the query and then `resolve(with:)`, which is where `#match?`, `#eq?`,
/// `#any-of?` and every other predicate is evaluated. Its synchronous half
/// (`TreeSitterClient.highlightsProvider.syncValue`) returns the raw captures and
/// skips that step, so a pattern guarded by a predicate matches as if it were not
/// guarded at all. The first paint of a buffer goes the asynchronous way and comes
/// out right; an injected sub-language finishes parsing later and is repainted the
/// synchronous way, and so is any range an edit invalidates. The visible symptom
/// was the bash query's `((command (_) @constant) (#match? @constant "^-"))`:
/// inside a Make recipe or a Markdown `sh` fence every word after the command
/// name turned `constant`, not just the `-flags`.
///
/// `TextViewHighlighter` builds its token provider privately, so the provider
/// cannot be swapped, and the synchronous output has already lost the pattern
/// information a re-filter would need. No Neon revision resolves predicates on
/// that path. So this class assembles the same parts from Neon's public API —
/// `TreeSitterClient`, `TextViewSystemInterface`, `TextSystemStyler`,
/// `RangeInvalidationBuffer`, a storage delegate and the scroll observation —
/// and hands the styler a token provider whose synchronous half always declines.
/// Every request then goes through the resolving path. The cost is that a range is
/// restyled one main-actor hop after it is invalidated instead of immediately —
/// the same hop the first paint already takes. Because every paint is now
/// asynchronous, overlapping requests can finish out of order, so a request
/// superseded by an invalidation or an edit while in flight paints nothing and
/// re-queues its range instead of painting over a newer answer.
///
/// The injection resolver is fixed here (`SyntaxLanguageConfiguration`'s
/// `configuration(forInjectionName:)`), so the six attaching sites differ only in
/// the root grammar and the attribute provider. `InjectedHighlightPredicateTests`
/// pins the behaviour; `app-editor-overlays.md` holds the reasoning.
@MainActor
final class PredicateResolvingHighlighter {
    private typealias Styler = TextSystemStyler<TextViewSystemInterface>

    let textView: TextView

    private let styler: Styler
    private let interface: TextViewSystemInterface
    private let client: TreeSitterClient
    private let buffer = RangeInvalidationBuffer()
    private let storageDelegate = HighlighterStorageDelegate()

#if os(iOS)
    private var frameObservation: NSKeyValueObservation?
    private var lastVisibleRange = NSRange(location: 0, length: 0)
#endif

    /// Attaches to `textView`, becoming its text storage's delegate, and starts
    /// observing its enclosing scroll view if it already has one. Throws when the
    /// grammar fails to start the parser; every caller degrades to plain text.
    init(
        textView: TextView,
        languageConfiguration: LanguageConfiguration,
        attributeProvider: @escaping TokenAttributeProvider
    ) throws {
        self.textView = textView
        let interface = TextViewSystemInterface(textView: textView, attributeProvider: attributeProvider)
        self.interface = interface
        let buffer = self.buffer
        let client = try TreeSitterClient(
            rootLanguageConfig: languageConfiguration,
            configuration: .init(
                // Resolve injected sub-languages (Markdown's `markdown_inline`,
                // fenced code, a Make recipe's shell, HTML's script and style).
                languageProvider: { name in
                    SyntaxLanguageConfiguration.configuration(forInjectionName: name)
                },
                contentProvider: { LanguageLayer.Content(string: interface.textStorage.string, limit: $0) },
                contentSnapshopProvider: {
                    LanguageLayer.ContentSnapshot(string: interface.textStorage.string, limit: $0)
                },
                lengthProvider: { interface.content.currentLength },
                invalidationHandler: { buffer.invalidate(.set($0)) },
                locationTransformer: { _ in nil }
            )
        )
        self.client = client

        // The text provider is read through `interface` at request time, so the
        // predicates are always evaluated against the current content.
        let resolving = client.tokenProvider(with: { interface.content.string.predicateTextProvider($0, $1) })
        let generation = StyleGeneration()
        // A caller detaches this highlighter by releasing it and clearing the
        // storage's delegate, but the buffer, styler and client keep each other
        // alive through their closures, and the text view is reused for the next
        // file. Work still queued after that must not start a new request.
        let isAttached = { [weak textView, weak storageDelegate = self.storageDelegate] () -> Bool in
            guard let textView, let storageDelegate else { return false }
#if os(macOS)
            return textView.textStorage?.delegate === storageDelegate
#else
            return textView.textStorage.delegate === storageDelegate
#endif
        }
        let tokenProvider = TokenProvider(
            // Declining is the whole fix: Neon's synchronous answer skips the
            // predicates, so the styler must always take the asynchronous one.
            syncValue: { _ in nil },
            mainActorAsyncValue: { range in
                let requested = generation.value
                let application = await resolving.async(range)
                guard generation.value == requested else {
                    // An invalidation or an edit landed while this request was
                    // in flight. Neon runs overlapping requests concurrently and
                    // marks whichever finishes `success`, so a request issued
                    // before an injected layer finished parsing could land after
                    // the repaint that parse caused and leave the block plain.
                    // Paint nothing, and once the styler has recorded this
                    // range as valid, ask for it again — unless it was detached.
                    DispatchQueue.main.async {
                        guard isAttached() else { return }
                        buffer.invalidate(.range(range))
                    }
                    return .noChange
                }
                return application
            }
        )
        let styler = Styler(textSystem: interface, tokenProvider: tokenProvider)
        self.styler = styler

        buffer.invalidationHandler = { target in
            guard isAttached() else { return }
            generation.value += 1
            styler.invalidate(target)
            styler.validate()
        }

        storageDelegate.willChangeContent = { range, _ in
            buffer.beginBuffering()
            client.willChangeContent(in: range)
        }
        storageDelegate.didChangeContent = { range, delta in
            generation.value += 1
            let adjustedRange = NSRange(location: range.location, length: range.length - delta)
            client.didChangeContent(in: adjustedRange, delta: delta)
            styler.didChangeContent(in: adjustedRange, delta: delta)
            // Styling is unsafe mid-edit and TextKit offers no hook for when it
            // becomes safe; like Neon, let the run loop turn first.
            DispatchQueue.main.async {
                buffer.endBuffering()
            }
        }

#if os(macOS)
        guard let storage = textView.textStorage else { throw TextViewHighlighterError.noTextStorage }
        storage.delegate = storageDelegate
#else
        textView.textStorage.delegate = storageDelegate
#endif

        observeEnclosingScrollView()
        buffer.invalidate(.all)
    }

    /// Restyles whatever becomes visible as the enclosing scroll view scrolls or
    /// resizes. A text view not yet inside a scroll view is not observed, as with
    /// Neon's own highlighter.
    private func observeEnclosingScrollView() {
#if os(macOS)
        guard let scrollView = textView.enclosingScrollView else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleContentChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleContentChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
#else
        frameObservation = textView.observe(\.contentOffset) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastVisibleRange = self.textView.visibleTextRange
                DispatchQueue.main.async {
                    guard self.textView.visibleTextRange == self.lastVisibleRange else { return }
                    self.styler.validate(.range(self.lastVisibleRange))
                }
            }
        }
#endif
    }

#if os(macOS)
    @objc private func visibleContentChanged(_ notification: NSNotification) {
        styler.validate(.range(textView.visibleTextRange))
    }
#endif
}

/// Counts the styler's invalidations and the buffer's edits, so a highlight
/// request can tell whether anything superseded it while it was in flight.
@MainActor
private final class StyleGeneration {
    var value = 0
}

/// Forwards character edits — never attribute-only ones, which styling itself
/// causes — to the highlighter. Neon's equivalent is internal to Neon.
private final class HighlighterStorageDelegate: NSObject, NSTextStorageDelegate {
    var willChangeContent: (NSRange, Int) -> Void = { _, _ in }
    var didChangeContent: (NSRange, Int) -> Void = { _, _ in }

#if os(macOS)
    typealias EditActions = NSTextStorageEditActions
#else
    typealias EditActions = NSTextStorage.EditActions
#endif

    func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        willChangeContent(editedRange, delta)
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        didChangeContent(editedRange, delta)
    }
}
#endif
