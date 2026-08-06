#if os(macOS)
import SwiftUI
import AppKit

/// The JetBrains-style find/replace bar shown directly above the editor.
///
/// Thin and untested like the rest of `Sources/Pisaka`: it renders
/// `EditorSearchState` and writes the user's input straight back into it. Every
/// decision — what matches, which one is current, what a replacement expands to —
/// belongs to `EditorSearchController` (dispatch) and `PisakaCore.TextSearchEngine`
/// (the rules), so nothing here computes anything about the buffer.
///
/// The bar re-runs the search implicitly: each field/toggle write is a
/// `@Published` change on the state, which invalidates `CodeEditorView` (an
/// `@ObservedObject` of the same state) and so reaches the controller through
/// `updateNSView`. There is deliberately no debounce — see the type-level comment
/// on `EditorSearchController` for that decision and its known headroom.
struct SearchBarView: View {
    @ObservedObject var search: EditorSearchState

    /// Focus for the query field, driven by `EditorSearchState.focusRequest` so a
    /// repeated ⌘F while the bar is already open re-focuses it (and selects its
    /// contents) rather than doing nothing.
    @FocusState private var isQueryFocused: Bool

    /// The window this bar is drawn in, resolved by `WindowAccessor` below.
    ///
    /// `takeFocus()` needs it to tell its *own* field editor from whichever one
    /// happens to be focused elsewhere in the app — see the note there.
    @State private var barWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            findRow
            if search.isReplaceExpanded {
                replaceRow
            }
            if let error = search.errorText {
                // An invalid regular expression reports its own reason inline, in
                // red — never as an alert: the pattern is being typed, so a modal
                // would fire on every intermediate keystroke.
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(NSColor.systemRed))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(NSColor.controlBackgroundColor))
        .background(WindowAccessor { window in
            // Identity-compared before writing: `updateNSView` runs on every pass,
            // and an unconditional `@State` write would invalidate the view that
            // scheduled it.
            if barWindow !== window { barWindow = window }
        })
        // Esc closes the bar and drops the highlight, wherever the focus sits
        // inside it. (The editor itself handles Esc through
        // `EditorTextView.cancelOperation`, so both sides behave identically.)
        .onExitCommand { search.close() }
        .onAppear { takeFocus() }
        .onChange(of: search.focusRequest) { _ in takeFocus() }
    }

    // MARK: - Rows

    private var findRow: some View {
        HStack(spacing: 6) {
            // Expands/collapses the replace row. Kept as a disclosure chevron on
            // the leading edge (JetBrains/Xcode convention) so the two rows read as
            // one control rather than two bars.
            Button {
                search.isReplaceExpanded.toggle()
            } label: {
                Image(systemName: search.isReplaceExpanded ? "chevron.down" : "chevron.right")
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(search.isReplaceExpanded ? "Hide replace" : "Show replace")

            TextField("Find", text: $search.pattern)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 240)
                .focused($isQueryFocused)
                // Enter steps to the next match, matching every other editor's
                // find bar; the bar stays open and focused.
                .onSubmit { search.findNext() }

            toggle("Aa", isOn: $search.caseSensitive, help: "Match case")
            toggle("ab", isOn: $search.wholeWord, help: "Words")
            toggle(".*", isOn: $search.isRegex, help: "Regular expression")

            Text(counterText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)

            Button { search.findPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find previous")
            .disabled(!search.hasMatches)

            Button { search.findNext() } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find next")
            .disabled(!search.hasMatches)

            Spacer(minLength: 4)

            Button { search.close() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 6) {
            // Keeps the replace field aligned under the query field, past the
            // disclosure chevron.
            Spacer().frame(width: 12)

            TextField("Replace", text: $search.template)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 240)
                // Enter in the replace field replaces the current match, so the
                // common "type, Enter, Enter, …" walk works without the mouse.
                .onSubmit { search.replaceCurrent() }

            Button("Replace") { search.replaceCurrent() }
                .disabled(!search.hasMatches)

            Button("Replace All") { search.replaceAll() }
                .disabled(!search.hasMatches)

            Spacer(minLength: 4)
        }
    }

    // MARK: - Pieces

    /// One of the three query-mode toggles (`Aa`, `ab`, `.*`), highlighted while on.
    private func toggle(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.25) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.primary)
        .help(help)
    }

    /// The `3/17` match counter.
    ///
    /// Blank while the query cannot run at all — an invalid regular expression
    /// (whose reason is shown below instead) or an empty field, which is
    /// incomplete input rather than a failed search. A pattern that simply matches
    /// nothing says so, since that is a real answer.
    ///
    /// "Empty" is the *trimmed* field, because that is where `TextSearchEngine`
    /// draws the line: it throws `.emptyPattern` for a whitespace-only pattern
    /// too ("an empty field is 'no query', not a search for spaces"), so the
    /// controller never ran a search — reporting "No results" for it would state
    /// an answer nothing computed.
    private var counterText: String {
        if search.errorText != nil { return "" }
        if search.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        guard search.matchCount > 0 else { return "No results" }
        guard let index = search.currentIndex else { return "\(search.matchCount)" }
        return "\(index + 1)/\(search.matchCount)"
    }

    // MARK: - Focus

    /// Focus the query field and select its contents.
    ///
    /// The select-all half has to go through the *field editor* — SwiftUI's
    /// `TextField` exposes no selection API — so it reaches for the shared editor
    /// AppKit has just installed as the window's first responder. It is deferred by
    /// one main-loop turn because `@FocusState` is applied on the next update, so
    /// reading the first responder synchronously would still find the previous one
    /// (or none).
    ///
    /// The `isFieldEditor` check is load-bearing, not defensive: the deferred block
    /// is *not* ordered after SwiftUI's focus pass, and the first responder it may
    /// still find is the code editor's own `NSTextView` — where `selectAll` would
    /// select the entire document (and, through the selection change, reset the
    /// current match to the top of the file). Only the shared field editor is ever
    /// selected; anything else simply gets the focus without the selection.
    ///
    /// The responder is resolved through **this bar's own window**, not
    /// `NSApp.keyWindow`, and only while that window is key. ⌘F is an app-wide
    /// `CommandMenu` item, so it fires with the Find in Files window (or any other)
    /// key — and *that* window's shared field editor is an `NSTextView` with
    /// `isFieldEditor == true`, so a key-window read passes the guard and selects
    /// the project-search query instead, where the user's next keystroke silently
    /// replaces the whole thing. Off in that case is the right answer: the bar still
    /// opens and asks for focus, it just does not reach into a window it does not
    /// own.
    private func takeFocus() {
        isQueryFocused = true
        DispatchQueue.main.async {
            guard let window = barWindow, window.isKeyWindow,
                  let responder = window.firstResponder as? NSTextView,
                  responder.isFieldEditor
            else { return }
            responder.selectAll(nil)
        }
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view, which SwiftUI itself does not
/// expose on macOS 13. The window is `nil` until the backing view is in a
/// hierarchy, so both hooks resolve it one main-loop turn later.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

#endif
