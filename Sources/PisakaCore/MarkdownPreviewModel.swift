import Foundation

/// The Markdown preview's ordering: everything about *when* the page changes.
///
/// The feature is deliberately cut so that this file holds the whole of the
/// timing and the app layer holds none of it. The parser is an app file (it is
/// the one `import Markdown`), the page is an app file (it is the one
/// `import WebKit`), and both reach this model as one-method seams — so the
/// generation token, the debounce, the memory of the last tree, the rule that a
/// theme change re-renders without re-parsing and the once-per-turn coalescing
/// of scroll lines are all asserted in `swift test` with neither a parser nor a
/// web view present.
///
/// **The glue above it decides nothing.** `MarkdownPreviewController` forwards
/// facts — this tab's text, this tab's document, this window's theme and code
/// font size — and every one of the methods below is total for the fact it is
/// handed: re-forwarding the document already shown is *not* a retarget, and
/// re-forwarding the text already parsed sends nothing. That is why the
/// controller holds no token, no debounce and no dirty flag: there is nothing
/// left for it to hold.
///
/// **The generation token** is the cross-cutting one, obeyed the way every async
/// model here obeys it: captured *synchronously* before the hop, re-checked
/// after every suspension, and a run that comes back to find it moved publishes
/// nothing at all. It is bumped by a text change, by a retarget and by a clear —
/// each of which invalidates a parse in flight — and it is what makes a slow
/// parse of an old buffer harmless rather than a body that flickers backwards.
///
/// **A reader.** Like the symbol index and the LSP client, this layer never
/// raises `autosave.suspend()`/`beginRevert()` and is never gated by them: it
/// reads a buffer the editor already holds and writes nothing anywhere — not the
/// worktree, not a cache, not the session. Its only persisted state is the two
/// `SettingsStore` preferences, which it does not own either.
///
/// **No `@Published` state, and that is the one departure from the
/// `DiagnosticsModel`/`LeetCodeJudgeModel` mould it otherwise follows.** The
/// preview's surface is the page, not a SwiftUI view: everything this model
/// decides leaves through ``MarkdownPreviewPageSink``, so a published mirror of
/// it would be a second copy of the page's state that nothing reads and that
/// could disagree with the page itself.
@MainActor
public final class MarkdownPreviewModel {

    /// The two facts the shell is composed from — and, since a size is also
    /// settable on a page already loaded, the pair a change *within* which
    /// decides whether the page is reloaded or merely told a number.
    ///
    /// A value, so "did the appearance change" is one comparison rather than
    /// two, and so the *un*set state — no shell has been installed yet — is
    /// `nil` rather than a pair of sentinel numbers.
    private struct Appearance: Equatable {
        var theme: MarkdownPreviewTheme
        var fontSize: Double
    }

    // MARK: - Seams

    /// Text in, tree out. `Sendable` and not main-actor isolated, because the
    /// parse is the one part of an update worth doing off the main actor.
    private let parser: any MarkdownParsing

    /// The page. Held strongly: the window owns this model and the page
    /// together, and the page holds no reference back, so there is no cycle to
    /// break and no moment where a live model is driving a page that has gone.
    private let sink: any MarkdownPreviewPageSink

    /// How long a burst of keystrokes is allowed to run before the preview
    /// answers it.
    ///
    /// Long enough that typing a word is one parse rather than five, short
    /// enough that the answer still reads as live. The *first* render after a
    /// retarget does not wait for it — see ``retarget(to:text:)``.
    public var debounceInterval: TimeInterval = 0.3

    /// The debounce's wait, as a seam.
    ///
    /// Injectable for the same reason `LeetCodeJudgeModel`'s is: the whole
    /// ordering — including the case where a second edit lands while the first
    /// parse is still running — runs deterministically in `swift test` and adds
    /// no wall-clock time to it.
    public var sleep: (TimeInterval) async -> Void = { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - What the page is showing

    /// The document being previewed. The renderer needs it to resolve relative
    /// images, and the retarget rule compares against it.
    public private(set) var context: MarkdownDocumentContext = .none

    /// The buffer's text as last forwarded — the input a parse is made from, and
    /// what an unchanged re-forward is compared against.
    private var text = ""

    /// The last tree parsed for ``text``.
    ///
    /// Held precisely so a theme or font change can re-render without asking the
    /// parser again: the tree does not depend on the appearance, and re-parsing
    /// a large document to change a colour is work the page can see.
    private var lastDocument: MarkdownDocument?

    /// The body the page is currently showing, or `nil` when it is showing none
    /// — which is also what a freshly reloaded shell is, since the shell ships
    /// its container empty.
    ///
    /// It is what makes an update that would change nothing send nothing: an
    /// edit inside a code fence's trailing whitespace, or a keystroke undone
    /// before the debounce elapsed, re-renders to the same markup and stops
    /// here rather than at the page.
    private var lastBody: String?

    /// The theme and font size the installed shell was composed from, or `nil`
    /// when no shell has been installed at all.
    private var appearance: Appearance?

    // MARK: - Ordering

    /// The generation token. See the type's note.
    private var generation = 0

    /// The parse in flight, cancelled by whatever supersedes it.
    ///
    /// Cancellation is a courtesy, not the mechanism: a parse already running
    /// off the main actor runs to completion regardless, and it is the token —
    /// re-checked when it returns — that keeps it from publishing.
    private var renderTask: Task<Void, Never>?

    /// The scroll line waiting to be sent, and whether a flush is already
    /// queued for this turn of the main run loop. See ``noteScrolled(toLine:)``.
    private var pendingScrollLine: Int?
    private var isScrollFlushScheduled = false

    /// The line last *sent* to the page, for the current document.
    ///
    /// A reloaded shell ships its container empty and its scroll position at the
    /// top, so a reader who switched to dark mode mid-document would be thrown
    /// back to the first line — and the editor has nothing to say about it, its
    /// clip view's bounds not having moved, so nothing would put them back until
    /// they happened to scroll again. (A code-zoom step is no longer one of the
    /// moves that can do this: it sets two properties on the document already
    /// loaded and never reaches this memory at all.) That is
    /// the argument ``noteScrolled(toLine:)`` already makes for holding a line
    /// reported before a body exists, read at the other end of the document's
    /// life: the memory is what a reload re-offers as pending.
    ///
    /// It describes *this* document, so it is forgotten wherever
    /// ``pendingScrollLine`` is — a retarget and a clear.
    private var lastScrolledLine: Int?

    public init(parser: any MarkdownParsing, sink: any MarkdownPreviewPageSink) {
        self.parser = parser
        self.sink = sink
    }

    // MARK: - The facts the glue forwards

    /// The window's theme and code font size.
    ///
    /// **Two halves, and which one runs is decided by the theme.** A theme
    /// change **reloads the shell and re-renders the body from the last tree**,
    /// because every colour in the page lives in the shell's own stylesheet and
    /// the tree does not depend on any of them; the parser is not asked again —
    /// the scripted parser's record is what pins that — which is the difference
    /// between switching to dark and re-opening the file. A change of the **font
    /// size alone** is one call into the document already loaded: the two sizes
    /// are custom properties, so setting them is the whole change, and a code
    /// zoom step therefore costs neither a page load, nor a re-render, nor a
    /// second pass of the diagram renderer.
    ///
    /// The in-place path needs **no scroll restore**, and that is not an
    /// omission: the reload's one exists because a fresh document starts at the
    /// top of an empty container, and here the document is not replaced — the
    /// page keeps its body, its scroll offset and its rendered diagrams, and
    /// re-sending the remembered line would move a reader who had not asked to
    /// be moved. For the same reason it touches neither ``lastBody``, the
    /// pending line, the tree nor the parser: nothing about what the page is
    /// showing became false.
    ///
    /// The shell still embeds the size it was composed with, so this is a step
    /// *from* that shell rather than a second source of truth: the appearance
    /// recorded here is what a later reload — a theme switch, a dead page — is
    /// composed from, and both readings go through
    /// ``MarkdownPreviewPage/fontSizes(for:)``.
    ///
    /// The first call installs the shell: before it there is no document at all,
    /// so there is nothing for a size to be set *on* — which is why the
    /// comparison is against an optional and why an absent appearance takes the
    /// reload path whatever moved.
    public func updateAppearance(theme: MarkdownPreviewTheme, fontSize: Double) {
        let next = Appearance(theme: theme, fontSize: fontSize)
        guard appearance != next else { return }

        if let current = appearance, current.theme == next.theme {
            appearance = next
            sink.evaluate(MarkdownPreviewPage.fontSizeUpdateSource(fontSize: next.fontSize))
            return
        }

        appearance = next

        // The reloaded document ships its container empty, so whatever the page
        // was showing is gone: recording that here is what lets the body be
        // re-sent even though it is byte-for-byte the one already rendered.
        lastBody = nil
        pendingScrollLine = pendingScrollLine ?? lastScrolledLine
        sink.reloadShell(html: MarkdownPreviewPage.html(theme: theme, fontSize: fontSize))
        publishBody()
    }

    /// The page is gone: the document this model was driving no longer exists,
    /// and whatever the page was showing went with it.
    ///
    /// **The one fact only the app half can observe, and the one recovery only
    /// this half can perform.** A web content process can die — a crash, or the
    /// system reclaiming it — and WebKit puts nothing back on its own; but the
    /// shell is a string this model composed and the body is one only this model
    /// still remembers, so the page half has nothing to reload *from*. It
    /// therefore reports the fact and the shell and the body are installed
    /// again, from the tree already parsed. The parser is not asked: the buffer
    /// did not change, only the page did.
    ///
    /// Not doing this leaves a blank pane for the rest of the window's life.
    /// Every method above is deliberately a no-op for a fact that did not move
    /// — ``updateAppearance(theme:fontSize:)`` returns early on an unchanged
    /// appearance, ``publish(body:)`` on an unchanged body — so nothing the user
    /// can do would send anything: typing re-renders markup already recorded as
    /// shown, and hiding and showing the pane re-forwards facts that did not
    /// change. Those early returns are right; what was missing is the one event
    /// that makes the memory they compare against false.
    ///
    /// Before the first ``updateAppearance(theme:fontSize:)`` there is no shell
    /// to reinstall and nothing to recover, which is what the guard says.
    public func pageIsGone() {
        guard let appearance else { return }
        lastBody = nil
        pendingScrollLine = pendingScrollLine ?? lastScrolledLine
        sink.reloadShell(html: MarkdownPreviewPage.html(theme: appearance.theme, fontSize: appearance.fontSize))
        publishBody()
    }

    /// The document the preview is pointed at, with the text it holds.
    ///
    /// A **retarget** clears the body, forgets the tree and parses immediately
    /// rather than after the debounce: the pane is showing another file's
    /// document, and 300 ms of the previous tab's content beside the new tab's
    /// editor is worse than a blank pane for the same 300 ms.
    ///
    /// Forwarding the context already shown is not a retarget — it is a text
    /// change, judged as one. That is what lets the controller call this on
    /// every selection change without comparing anything itself.
    public func retarget(to context: MarkdownDocumentContext, text: String) {
        guard context != self.context else {
            noteTextChanged(text)
            return
        }

        self.context = context
        self.text = text
        lastDocument = nil
        pendingScrollLine = nil
        lastScrolledLine = nil
        publish(body: "")
        render(debounced: false)
    }

    /// The active buffer's text.
    ///
    /// Debounced, and idempotent: text identical to what is already parsed (or
    /// already on its way to being parsed) schedules nothing, so a
    /// notification that fires on a selection change or a save costs no parse.
    public func noteTextChanged(_ text: String) {
        guard text != self.text else { return }
        self.text = text
        render(debounced: true)
    }

    /// Stop previewing anything: a tab that is not Markdown became active, the
    /// preference was switched off, or the project folder changed.
    ///
    /// The body is cleared and the token moves, so a parse in flight publishes
    /// nothing when it lands. The shell stays installed — it is the page, not
    /// the document, and reloading it would only cost a second load the next
    /// time a Markdown tab is selected.
    public func clear() {
        context = .none
        text = ""
        lastDocument = nil
        pendingScrollLine = nil
        lastScrolledLine = nil
        generation += 1
        renderTask?.cancel()
        renderTask = nil
        publish(body: "")
    }

    /// The editor's top visible line, as ``MarkdownScrollRule`` answered it.
    ///
    /// **Coalesced to one call per turn of the main run loop, and never by a
    /// timer.** A scroll gesture delivers a bounds change per frame, each of
    /// which would otherwise be an `evaluateJavaScript` round trip; marking the
    /// model dirty and flushing from a main-actor `Task` — which runs after the
    /// current synchronous work drains — collapses the whole burst into one
    /// `scrollToLine` carrying the last line. A timer would add a latency nobody
    /// asked for and a second clock to reason about; this adds neither.
    ///
    /// **A line reported while the page is showing no body is held, not
    /// dropped.** There is no element to scroll to yet, so nothing is *sent* —
    /// but the report is recorded and flushed by the publish that gives the page
    /// its body. That is not a refinement of the coalescing rule, it is what
    /// makes the feature start in the right place: the editor's one observation
    /// of a scroll is its clip view's bounds change, and on the two moves that
    /// begin a preview — a switch to a Markdown tab whose viewport is restored
    /// mid-document, and the pane being shown over an already-scrolled one — the
    /// bounds change arrives in the same turn as ``retarget(to:context:)``,
    /// while the parse is still off the main actor. Dropping it left the preview
    /// pinned to the top of the document until the user happened to scroll
    /// again, which for a file being read rather than edited may be never.
    ///
    /// A line belonging to the *outgoing* document is still dropped: the
    /// retarget and the clear both null the pending line, so what is held here
    /// can only ever describe the document the page is about to show.
    public func noteScrolled(toLine line: Int) {
        pendingScrollLine = line
        scheduleScrollFlush()
    }

    /// Queue this turn's one flush, unless a line is already waiting for it.
    ///
    /// Reached from the report above and from ``publishBody()``, which is the
    /// moment a held line becomes sendable.
    private func scheduleScrollFlush() {
        guard pendingScrollLine != nil, !isScrollFlushScheduled else { return }
        isScrollFlushScheduled = true
        Task { [weak self] in
            self?.flushScroll()
        }
    }

    // MARK: - Rendering

    /// Parse ``text`` and publish its body, discarding the answer if anything
    /// superseded it.
    ///
    /// The token is captured here, synchronously, before the hop — not inside
    /// the task, where it would already be the *next* run's.
    private func render(debounced: Bool) {
        generation += 1
        let token = generation
        let text = self.text
        let parser = self.parser
        let sleep = self.sleep
        let interval = debounceInterval

        renderTask?.cancel()
        renderTask = Task { [weak self] in
            if debounced {
                await sleep(interval)
            }
            guard let self, token == self.generation else { return }

            // Off the main actor: a large document is milliseconds of work that
            // would otherwise be milliseconds of a stalled editor.
            let document = await Task.detached(priority: .userInitiated) { parser.parse(text) }.value

            guard token == self.generation else { return }
            self.lastDocument = document
            self.publishBody()
        }
    }

    /// Render ``lastDocument`` into the page, or do nothing when there is none.
    ///
    /// The page now has a body, so a line reported before it did — the scroll
    /// the tab switch or the pane's appearance produced — becomes sendable here.
    /// Scheduled rather than sent, so it still costs one call per turn and still
    /// carries the last line reported.
    private func publishBody() {
        guard let lastDocument else { return }
        publish(body: MarkdownRenderer.body(for: lastDocument, context: context))
        scheduleScrollFlush()
    }

    /// Send `body` to the page, unless the page is already showing it.
    private func publish(body: String) {
        guard body != lastBody else { return }
        lastBody = body
        sink.evaluate(MarkdownPreviewPage.bodyUpdateSource(body: body))
    }

    /// The one scroll call a turn's worth of bounds changes produces.
    ///
    /// A page with no body has nothing to scroll to, so the line stays pending
    /// rather than being consumed: ``publishBody()`` schedules the flush again
    /// once there is one. See ``noteScrolled(toLine:)``.
    ///
    /// What is sent is also remembered, in ``lastScrolledLine``, so a shell
    /// reload can re-offer it and land the reader back where they were.
    private func flushScroll() {
        isScrollFlushScheduled = false
        guard let line = pendingScrollLine, lastDocument != nil else { return }
        pendingScrollLine = nil
        lastScrolledLine = line
        sink.evaluate(MarkdownPreviewPage.scrollToLineSource(line: line))
    }
}
