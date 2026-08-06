#if os(macOS)
import Foundation
import SwiftTreeSitter
import PisakaCore

/// Produces a `MinimapModel` for a file by parsing the whole text with
/// SwiftTreeSitter and mapping each highlight capture through
/// `SyntaxTokenKind`, then grouping per line into non-whitespace colored runs.
///
/// This is the minimap's *own* parse — deliberately separate from Neon's
/// (which only styles the visible range). Re-parses are debounced and skipped
/// entirely when the (file id, text, language) triple is unchanged, so typing
/// doesn't trigger redundant full-file parses. The heavy parse runs off the
/// main actor; only the `model` swap and `onChange` callback touch the main
/// actor.
///
/// A `nil` language (untitled / unknown extension) yields `.empty`, matching the
/// editor's plain-text path where no highlighter is attached.
@MainActor
final class MinimapTokenizer {
    /// The most recently computed model. Replaced on the main actor.
    private(set) var model: MinimapModel = .empty

    /// Identifies the input the current `model` was built from, so an unchanged
    /// text/version is a no-op rather than a redundant re-parse.
    private var cacheKey: CacheKey?

    /// The in-flight debounce/compute task; cancelled when a newer update lands.
    private var pendingTask: Task<Void, Never>?

    /// Serializes the heavy off-main parses so at most one runs at a time. The
    /// previous code launched each parse via `Task.detached`, which is
    /// unstructured: cancelling `pendingTask` did not cancel the detached parse,
    /// so rapid edits or tab switches (the latter parse `immediate`, skipping the
    /// debounce) could pile up several concurrent full-file parses. Routing them
    /// through an actor means a superseded parse waits its turn and then bails on
    /// the cancellation check below instead of running, and never overlaps the
    /// live one.
    private let parseRunner = ParseRunner()

    /// Monotonic token guarding against a stale background parse overwriting a
    /// newer model after the inputs changed mid-flight.
    private var generation = 0

    /// Debounce delay before a (non-immediate) re-parse, coalescing rapid edits.
    private let debounceInterval: Duration = .milliseconds(150)

    private struct CacheKey: Equatable {
        let fileID: UUID
        let textHash: Int
        let language: SyntaxLanguage?
    }

    /// Recompute the model for `text` in `language`, debounced unless
    /// `immediate` (used for tab/language switches that should refresh at once).
    ///
    /// Does nothing when the inputs match the current model. `onChange` runs on
    /// the main actor after `model` is replaced, so the view can redraw.
    func update(
        text: String,
        language: SyntaxLanguage?,
        fileID: UUID,
        immediate: Bool = false,
        onChange: @escaping () -> Void
    ) {
        let key = CacheKey(fileID: fileID, textHash: text.hashValue, language: language)
        if key == cacheKey {
            // `model` already matches the requested input. But a parse for a
            // *different* key may still be in flight (its `cacheKey` is only set
            // on completion); letting it land would overwrite the correct model
            // with a now-stale file's overview — e.g. switching A→B→A faster than
            // B's off-main parse finishes. Cancel it and advance the generation so
            // its result is discarded by the staleness guard below.
            if pendingTask != nil {
                pendingTask?.cancel()
                pendingTask = nil
                generation += 1
            }
            return
        }

        generation += 1
        let token = generation
        pendingTask?.cancel()

        let interval = debounceInterval
        pendingTask = Task { [weak self, parseRunner] in
            if !immediate {
                try? await Task.sleep(for: interval)
            }
            if Task.isCancelled { return }

            // Parse off the main actor (the runner is its own actor) — a full-file
            // parse can be heavy. The runner serializes parses and re-checks
            // cancellation when this one reaches the front of its queue, so a
            // superseded update returns `nil` here without doing the heavy work.
            guard let model = await parseRunner.parse(text: text, language: language) else { return }

            if Task.isCancelled { return }
            guard let self, token == self.generation else { return }
            self.model = model
            self.cacheKey = key
            onChange()
        }
    }

    /// Clear any cached model and cancel an in-flight parse (e.g. on teardown).
    func reset() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        cacheKey = nil
        model = .empty
    }

    /// The pure, main-actor-free parse: text + language → line-indexed runs.
    ///
    /// Returns `.empty` when no grammar/highlights query is available (no
    /// detected language or a packaging failure), so the minimap simply draws
    /// nothing, mirroring the editor's plain-text fallback.
    nonisolated static func computeModel(text: String, language: SyntaxLanguage?) -> MinimapModel {
        guard
            let language,
            let configuration = SyntaxLanguageConfiguration.configuration(for: language),
            let highlightsQuery = configuration.queries[.highlights]
        else {
            return .empty
        }

        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return MinimapModel(runs: [[]]) }

        let parser = Parser()
        do {
            try parser.setLanguage(configuration.language)
        } catch {
            return .empty
        }
        guard let tree = parser.parse(text), let root = tree.rootNode else {
            return .empty
        }

        // `highlights()` returns captures sorted least- to most-specific, so
        // painting them in order lets a more specific capture (e.g.
        // `variable.parameter`) overwrite the broader one over the same range —
        // mirroring how Neon's later styling wins in the editor.
        let cursor = highlightsQuery.execute(node: root, in: tree)
        let highlights = cursor.resolve(with: Predicate.Context(string: text)).highlights()

        // Per-character kind; non-captured non-whitespace stays `.plain` so the
        // minimap still draws body text (in the default label color) rather than
        // leaving holes.
        var kinds = [SyntaxTokenKind](repeating: .plain, count: length)
        for named in highlights {
            let kind = SyntaxTokenKind(captureName: named.name)
            guard kind != .plain else { continue }
            let range = named.range
            let lower = max(0, range.location)
            let upper = min(length, range.location + range.length)
            if lower >= upper { continue }
            for index in lower..<upper { kinds[index] = kind }
        }

        // Pure grouping (line splitting + run building) lives in `PisakaCore`
        // where it is dependency-free and unit-tested; only the parse above is
        // view-layer-specific.
        return MinimapModel.build(text: text, kinds: kinds)
    }
}

/// Runs full-file parses off the main actor, one at a time.
///
/// An actor processes one call at a time, so a synchronous (non-suspending)
/// `parse` holds the actor until it returns — two parses can never run
/// concurrently. A parse that has been superseded while waiting in the actor's
/// queue sees its owning task's cancellation when it finally starts and returns
/// `nil` immediately, skipping the heavy work. (`Task.isCancelled` here reflects
/// the awaiting `pendingTask`, since the actor hop stays within that task.) The
/// single parse already executing when cancellation lands can't be interrupted
/// mid-tree-sitter-parse and runs to completion, but its result is discarded by
/// the caller's generation/cancellation guards — at most one parse is ever live.
private actor ParseRunner {
    func parse(text: String, language: SyntaxLanguage?) -> MinimapModel? {
        if Task.isCancelled { return nil }
        return MinimapTokenizer.computeModel(text: text, language: language)
    }
}

#endif
