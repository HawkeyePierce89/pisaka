import XCTest
@testable import PisakaCore

/// The preview's ordering: what reaches the page, in what order, and — mostly —
/// what deliberately does not.
///
/// Four properties carry this suite, and each is a cross-cutting rule of this
/// repository applied on the preview's axis:
///
/// - **A superseded parse publishes nothing at all.** Both racers are held on
///   their own gate and resumed in call order, so the stale one finishes *first*
///   and would overwrite the newer body if the token were not checked. That is
///   what makes the assertion real rather than a coincidence of scheduling.
/// - **An appearance change re-renders without re-parsing.** The evidence is the
///   scripted parser's record being byte-for-byte unchanged across a theme
///   switch, and the page still receiving the body.
/// - **The first render after a retarget does not wait.** The debounce is held
///   open for the whole test, and the retarget's body arrives anyway while the
///   text change behind it does not.
/// - **A burst of scroll lines is one call.** Delivered in one turn of the main
///   run loop, they produce exactly one `scrollToLine`, carrying the last line.
///
/// Nothing here waits on a delay: every stage is a rendezvous on a signal that
/// must arrive (`Gate`, the parser's own records) and every assertion polls the
/// scripted sink rather than assuming a hop count.
@MainActor
final class MarkdownPreviewModelTests: XCTestCase {

    // MARK: - Harness

    private let documentContext = MarkdownDocumentContext(
        documentURL: URL(fileURLWithPath: "/project/README.md"),
        projectRoot: URL(fileURLWithPath: "/project")
    )

    private let otherContext = MarkdownDocumentContext(
        documentURL: URL(fileURLWithPath: "/project/docs/guide.md"),
        projectRoot: URL(fileURLWithPath: "/project")
    )

    /// The same file name under another opened folder — a folder switch, as the
    /// glue forwards it.
    private let otherProjectContext = MarkdownDocumentContext(
        documentURL: URL(fileURLWithPath: "/other/README.md"),
        projectRoot: URL(fileURLWithPath: "/other")
    )

    /// The body the default one-paragraph tree renders to, spelled once.
    private func body(for text: String) -> String {
        MarkdownRenderer.body(
            for: ScriptedMarkdownParser.defaultDocument(for: text),
            context: documentContext
        )
    }

    /// A model whose debounce is a no-op, for the cases that are not about the
    /// debounce. The wait itself is the seam, so this costs no wall-clock time.
    private func makeModel() -> (MarkdownPreviewModel, ScriptedMarkdownParser, ScriptedMarkdownPageSink) {
        let parser = ScriptedMarkdownParser()
        let sink = ScriptedMarkdownPageSink()
        let model = MarkdownPreviewModel(parser: parser, sink: sink)
        model.sleep = { _ in }
        return (model, parser, sink)
    }

    /// A debounce that only elapses when the test says so.
    private actor HeldSleep {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private(set) var requestedIntervals: [TimeInterval] = []

        func wait(_ interval: TimeInterval) async {
            requestedIntervals.append(interval)
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private func waitFor(
        _ description: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    /// Let every task already queued on this actor run, so an assertion that
    /// *nothing* was sent is made after the work that could have sent it.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - The token

    func testSupersededParseNeverPublishesOverANewerOne() async {
        let (model, parser, sink) = makeModel()
        let stale = parser.hold("first")
        let live = parser.hold("second")

        model.retarget(to: documentContext, text: "first")
        await parser.waitUntilParsing("first")

        model.noteTextChanged("second")
        await parser.waitUntilParsing("second")

        // Resumed in call order: the stale parse returns first, and would win if
        // the token were not re-checked after the hop.
        stale.release()
        await parser.waitUntilParsed("first")
        live.release()
        await parser.waitUntilParsed("second")

        await waitFor("the newer body") { sink.bodies.last == self.body(for: "second") }
        await settle()

        XCTAssertEqual(parser.parsed, ["first", "second"])
        XCTAssertEqual(sink.bodies, ["", body(for: "second")])
        XCTAssertFalse(sink.bodies.contains(body(for: "first")))
    }

    func testTextChangeToTheSameTextSchedulesNoParse() async {
        let (model, parser, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }

        model.noteTextChanged("alpha")
        await settle()

        XCTAssertEqual(parser.parsed, ["alpha"])
        XCTAssertEqual(sink.bodies, ["", body(for: "alpha")])
    }

    func testARenderThatChangesNothingSendsNothing() async {
        let (model, parser, sink) = makeModel()
        // Two different buffers, one tree: the page is already showing the body
        // this parse produced, so nothing crosses the seam a second time.
        let document = ScriptedMarkdownParser.defaultDocument(for: "same")
        parser.script("alpha", as: document)
        parser.script("alpha ", as: document)

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "same") }

        model.noteTextChanged("alpha ")
        await waitFor("the second parse") { parser.parsed.count == 2 }
        await settle()

        XCTAssertEqual(parser.parsed, ["alpha", "alpha "])
        XCTAssertEqual(sink.bodies, ["", body(for: "same")])
    }

    // MARK: - The debounce

    func testARetargetRendersImmediatelyAndATextChangeWaits() async {
        let parser = ScriptedMarkdownParser()
        let sink = ScriptedMarkdownPageSink()
        let model = MarkdownPreviewModel(parser: parser, sink: sink)
        let debounce = HeldSleep()
        model.sleep = { await debounce.wait($0) }

        model.retarget(to: documentContext, text: "opening")
        await waitFor("the immediate first body") { sink.bodies.last == self.body(for: "opening") }

        model.noteTextChanged("typed")
        await settle()
        XCTAssertEqual(parser.parsed, ["opening"], "a text change must wait for the debounce")

        await debounce.open()
        await waitFor("the debounced body") { sink.bodies.last == self.body(for: "typed") }

        let intervals = await debounce.requestedIntervals
        XCTAssertEqual(intervals, [model.debounceInterval])
    }

    func testDebounceIntervalIsThreeHundredMilliseconds() {
        let model = MarkdownPreviewModel(parser: ScriptedMarkdownParser(), sink: ScriptedMarkdownPageSink())
        XCTAssertEqual(model.debounceInterval, 0.3)
    }

    // MARK: - The appearance

    func testAppearanceChangeReloadsTheShellAndRerendersWithoutParsing() async {
        let (model, parser, sink) = makeModel()
        model.updateAppearance(theme: .light, fontSize: 13)

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }
        let parsedBefore = parser.parsed

        model.updateAppearance(theme: .dark, fontSize: 13)
        await settle()

        XCTAssertEqual(parser.parsed, parsedBefore, "a theme change must not re-parse")
        XCTAssertEqual(sink.shellReloads.count, 2)
        XCTAssertTrue(sink.shellReloads[0].contains(MarkdownPreviewTheme.light.background))
        XCTAssertTrue(sink.shellReloads[1].contains(MarkdownPreviewTheme.dark.background))
        // The reloaded shell ships an empty container, so the same body is sent
        // again rather than suppressed as unchanged.
        XCTAssertEqual(sink.bodies, ["", body(for: "alpha"), body(for: "alpha")])
    }

    func testAFontSizeChangeReloadsTheShellToo() async {
        let (model, _, sink) = makeModel()
        model.updateAppearance(theme: .light, fontSize: 13)
        model.updateAppearance(theme: .light, fontSize: 16)
        await settle()

        XCTAssertEqual(sink.shellReloads.count, 2)
        XCTAssertTrue(sink.shellReloads[1].contains("--font-size: 16px"))
    }

    func testAnUnchangedAppearanceReloadsNothing() async {
        let (model, _, sink) = makeModel()
        model.updateAppearance(theme: .light, fontSize: 13)
        model.updateAppearance(theme: .light, fontSize: 13)
        await settle()

        XCTAssertEqual(sink.shellReloads.count, 1)
    }

    // MARK: - Retarget and clear

    func testRetargetingToTheSameDocumentIsATextChange() async {
        let parser = ScriptedMarkdownParser()
        let sink = ScriptedMarkdownPageSink()
        let model = MarkdownPreviewModel(parser: parser, sink: sink)
        let debounce = HeldSleep()
        model.sleep = { await debounce.wait($0) }

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }

        // Same context, new text: debounced, so nothing lands while the wait is
        // held — a second retarget would have rendered immediately.
        model.retarget(to: documentContext, text: "beta")
        await settle()
        XCTAssertEqual(parser.parsed, ["alpha"])

        await debounce.open()
        await waitFor("the debounced body") { sink.bodies.last == self.body(for: "beta") }
    }

    func testRetargetingToAnotherDocumentClearsTheBodyFirst() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }

        model.retarget(to: otherContext, text: "beta")
        XCTAssertEqual(sink.bodies.last, "", "the previous file's body must go before the new one is parsed")
        XCTAssertEqual(model.context, otherContext)

        await waitFor("the second body") { sink.bodies.last != "" }
        XCTAssertEqual(
            sink.bodies,
            [
                "",
                body(for: "alpha"),
                "",
                MarkdownRenderer.body(
                    for: ScriptedMarkdownParser.defaultDocument(for: "beta"),
                    context: otherContext
                ),
            ]
        )
    }

    func testClearEmptiesTheBodyAndSendsNothingAfterwards() async {
        let (model, parser, sink) = makeModel()
        let held = parser.hold("alpha")

        model.retarget(to: documentContext, text: "alpha")
        await parser.waitUntilParsing("alpha")
        XCTAssertEqual(sink.bodies, [""])

        model.clear()
        held.release()
        await parser.waitUntilParsed("alpha")
        await settle()

        XCTAssertEqual(model.context, .none)
        XCTAssertEqual(sink.bodies, [""], "the parse in flight must publish nothing")
        XCTAssertEqual(sink.evaluatedSources.count, 1)

        model.noteScrolled(toLine: 4)
        await settle()
        XCTAssertEqual(sink.evaluatedSources.count, 1)
    }

    func testClearAfterARenderedBodyEmptiesThePage() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }

        model.clear()
        await settle()

        XCTAssertEqual(sink.bodies, ["", body(for: "alpha"), ""])
    }

    // MARK: - Scroll

    func testABurstOfScrollLinesIsOneCallCarryingTheLastLine() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }
        sink.clearEvents()

        // One turn of the main run loop: nothing between these three calls
        // suspends, so the flush cannot have run in between.
        model.noteScrolled(toLine: 3)
        model.noteScrolled(toLine: 7)
        model.noteScrolled(toLine: 11)

        await waitFor("the coalesced scroll") { !sink.scrolledLines.isEmpty }
        await settle()
        XCTAssertEqual(sink.scrolledLines, [11])
        XCTAssertEqual(sink.evaluatedSources.count, 1)

        // A second turn is a second call.
        model.noteScrolled(toLine: 2)
        await waitFor("the second scroll") { sink.scrolledLines.count == 2 }
        XCTAssertEqual(sink.scrolledLines, [11, 2])
    }

    /// A gesture's worth of bounds changes, as the editor actually delivers
    /// them: one per frame, all inside a single turn of the main run loop.
    ///
    /// The editor reports an offset per frame and the glue maps each one, so
    /// the model is what stands between a scroll gesture and sixty
    /// `evaluateJavaScript` round trips. Sixty calls in, one call out, carrying
    /// the line the gesture ended on.
    func testAWholeScrollGestureIsOneCallCarryingTheLineItEndedOn() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }
        sink.clearEvents()

        for line in 1...60 {
            model.noteScrolled(toLine: line)
        }

        await waitFor("the coalesced scroll") { !sink.scrolledLines.isEmpty }
        await settle()
        XCTAssertEqual(sink.scrolledLines, [60])
        XCTAssertEqual(sink.evaluatedSources.count, 1)
    }

    /// A scroll that a retarget overtook in the same turn.
    ///
    /// The line described the outgoing document, and the page is about to be
    /// showing another one, so it is dropped rather than sent — the alternative
    /// is a new file opening scrolled to a position taken from the old one.
    func testAPendingScrollIsDroppedByARetarget() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }
        sink.clearEvents()

        model.noteScrolled(toLine: 40)
        model.retarget(to: otherContext, text: "beta")

        await settle()
        XCTAssertEqual(sink.scrolledLines, [])
    }

    /// The same, for the clear: a tab that is not Markdown became active, or the
    /// preference went off, and the page is being emptied.
    func testAPendingScrollIsDroppedByAClear() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }
        sink.clearEvents()

        model.noteScrolled(toLine: 40)
        model.clear()

        await settle()
        XCTAssertEqual(sink.scrolledLines, [])
    }

    func testAScrollBeforeAnyBodySendsNothing() async {
        let (model, _, sink) = makeModel()

        model.noteScrolled(toLine: 9)
        await settle()

        XCTAssertTrue(sink.events.isEmpty)
    }

    /// The scroll a tab switch produces, which arrives while the new document is
    /// still being parsed.
    ///
    /// The editor's one observation of a scroll is its clip view's bounds
    /// change, and restoring a tab's viewport fires it in the same turn as the
    /// retarget — so this line is reported when the page has no body yet. Held
    /// rather than dropped, it is what makes the preview open where the editor
    /// is; dropped, the pane sat at the top of the document until the user
    /// scrolled again.
    func testAScrollReportedBeforeTheBodyIsSentOnceTheBodyLands() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        model.noteScrolled(toLine: 40)

        await waitFor("the first body") { sink.bodies.last == self.body(for: "alpha") }
        await waitFor("the held scroll") { !sink.scrolledLines.isEmpty }
        await settle()

        XCTAssertEqual(sink.scrolledLines, [40])
    }

    /// The same held line, still coalesced: a burst reported before the body
    /// lands is one call carrying the last of them, not one call each.
    func testABurstReportedBeforeTheBodyIsStillOneCall() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        for line in 1...60 {
            model.noteScrolled(toLine: line)
        }

        await waitFor("the held scroll") { !sink.scrolledLines.isEmpty }
        await settle()

        XCTAssertEqual(sink.scrolledLines, [60])
    }

    /// A line held across a retarget still belongs to the outgoing document, so
    /// the retarget's own null is what must win.
    ///
    /// This is the guard the held-line rule could plausibly have broken: the
    /// page ends up showing `beta`, and the position `alpha` was scrolled to
    /// must not be applied to it.
    func testAHeldScrollIsStillDroppedByARetargetBeforeTheBodyLands() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        model.noteScrolled(toLine: 40)
        model.retarget(to: otherContext, text: "beta")

        await waitFor("the second body") { sink.bodies.last == self.body(for: "beta") }
        await settle()

        XCTAssertEqual(sink.scrolledLines, [])
    }

    /// The same, for the clear: nothing held survives the page being emptied.
    func testAHeldScrollIsStillDroppedByAClearBeforeTheBodyLands() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        model.noteScrolled(toLine: 40)
        model.clear()

        await settle()

        XCTAssertEqual(sink.scrolledLines, [])
    }

    // MARK: - The three moves the app glue makes

    /// `MarkdownPreviewController` and `MarkdownPreviewPane` hold no ordering of
    /// their own: they forward the window's facts, and every case below is one of
    /// those forwards. They are asserted here, on the model, because that is
    /// where the behaviour is — the glue has no tests of its own for exactly this
    /// reason.

    /// A selection change from one Markdown tab to another.
    ///
    /// The pane is *not* rebuilt for it — one web view per window, retargeted —
    /// so the evidence is the shell being installed exactly once across both
    /// tabs while the body follows the selection.
    func testASelectionChangeRetargetsTheOnePageWithoutReloadingTheShell() async {
        let (model, _, sink) = makeModel()
        model.updateAppearance(theme: .light, fontSize: 13)

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first tab's body") { sink.bodies.last == self.body(for: "alpha") }

        model.retarget(to: otherContext, text: "beta")
        let expected = MarkdownRenderer.body(
            for: ScriptedMarkdownParser.defaultDocument(for: "beta"),
            context: otherContext
        )
        await waitFor("the second tab's body") { sink.bodies.last == expected }

        XCTAssertEqual(model.context, otherContext)
        XCTAssertEqual(sink.shellReloads.count, 1, "a tab switch must replace a body, never re-load a page")
    }

    /// A folder switch: the pane goes with the tab set, which clears, and comes
    /// back pointed at the new project.
    func testAFolderSwitchClearsTheBodyAndTheContext() async {
        let (model, _, sink) = makeModel()

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the first project's body") { sink.bodies.last == self.body(for: "alpha") }

        model.clear()
        XCTAssertEqual(model.context, .none)
        XCTAssertEqual(sink.bodies.last, "")

        model.retarget(to: otherProjectContext, text: "alpha")
        let expected = MarkdownRenderer.body(
            for: ScriptedMarkdownParser.defaultDocument(for: "alpha"),
            context: otherProjectContext
        )
        await waitFor("the second project's body") { sink.bodies.last == expected }
        XCTAssertEqual(model.context, otherProjectContext)
    }

    /// The preference going off, and coming back on.
    ///
    /// Off empties the page; the shell stays installed, so switching it back on
    /// costs a body and not a page load — which is what makes ⌘⇧P cheap.
    func testThePreferenceGoingOffEmptiesThePageAndLeavesTheShellInstalled() async {
        let (model, parser, sink) = makeModel()
        model.updateAppearance(theme: .dark, fontSize: 15)

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the body") { sink.bodies.last == self.body(for: "alpha") }

        model.clear()
        await settle()
        XCTAssertEqual(sink.bodies.last, "")
        XCTAssertEqual(sink.shellReloads.count, 1)

        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the body again") { sink.bodies.last == self.body(for: "alpha") }
        XCTAssertEqual(sink.shellReloads.count, 1, "the shell survives a clear")
        XCTAssertEqual(parser.parsed, ["alpha", "alpha"])
    }

    // MARK: - A page that died

    /// The web content process dies: both halves of the document are installed
    /// again, and the parser is not asked.
    ///
    /// The assertion that matters is the *body*, not the shell. Every method on
    /// this model is a no-op for a fact that did not move, so the page's memory
    /// — `lastBody` — is exactly what makes a blank pane unrecoverable: the body
    /// that must be re-sent is byte-for-byte the one already recorded as shown,
    /// which is why re-typing it, hiding the pane or switching back to the tab
    /// would all send nothing. Recovery is therefore only real if the same body
    /// crosses the seam a second time.
    func testAPageThatDiedIsInstalledAgainWithoutReParsing() async {
        let (model, parser, sink) = makeModel()
        model.updateAppearance(theme: .dark, fontSize: 15)
        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the body") { sink.bodies.last == self.body(for: "alpha") }

        sink.clearEvents()
        model.pageIsGone()
        await waitFor("the body, sent again") { sink.bodies.last == self.body(for: "alpha") }

        XCTAssertEqual(
            sink.shellReloads.count,
            1,
            "the shell is composed again from the appearance already forwarded: the reloaded page ships "
                + "its container empty, so a body with no shell under it would have nowhere to land"
        )
        XCTAssertEqual(
            parser.parsed,
            ["alpha"],
            "the buffer did not change — only the page did — so the tree in hand is re-rendered rather "
                + "than re-parsed, exactly as an appearance change is"
        )
    }

    /// A death before the first appearance was forwarded: nothing is installed,
    /// because there is no shell to compose and nothing was ever shown.
    func testAPageThatDiedBeforeAnyShellInstallsNothing() async {
        let (model, parser, sink) = makeModel()

        model.pageIsGone()
        await settle()

        XCTAssertEqual(sink.events, [])
        XCTAssertEqual(parser.parsed, [])
    }

    /// The next keystroke after a recovery still reaches the page.
    ///
    /// The recovery re-sends a body the model had already recorded, so this is
    /// the check that it re-*recorded* it too: a memory left cleared would make
    /// the following edit's body look new when it is not, and one left holding
    /// the pre-death value would be the same trap read from the other side.
    func testEditingAfterARecoveryStillPublishes() async {
        let (model, _, sink) = makeModel()
        model.updateAppearance(theme: .dark, fontSize: 15)
        model.retarget(to: documentContext, text: "alpha")
        await waitFor("the body") { sink.bodies.last == self.body(for: "alpha") }

        model.pageIsGone()
        await waitFor("the body, sent again") { sink.bodies.last == self.body(for: "alpha") }

        model.noteTextChanged("beta")
        await waitFor("the edit's body") { sink.bodies.last == self.body(for: "beta") }
    }
}
