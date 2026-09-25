#if os(macOS)
import SwiftUI
import PisakaCore

/// The commit dialog: a modal sheet over the main window.
///
/// On the left the changed files with three-state checkboxes and status badges; on
/// the right the selected file's unified diff with a checkbox on every changed line
/// (or a "committed as a whole" placeholder — see `CommitUnifiedDiffView`); at the
/// bottom the message field, the author line with local-config editing, the Amend
/// and "Push after commit" switches, and Commit/Cancel.
///
/// Thin and untested like the rest of the view layer: what may be committed
/// (`CommitGate`), what the commit will do (`CommitPlan`), what a checkbox's state
/// is (`CheckboxState`), what a whole-only file says instead of a diff
/// (`WholeOnlyReason`) and what a push would do (`PushPlan`) are all decided in
/// Core and merely displayed here. The commit itself is handed back to `PisakaApp`
/// through `onCommit`, which owns the writer coordination (autosave, the revert
/// gate) and the post-success refreshes — none of which a view may reach into.
///
/// Every colour is a chrome role, read from `\.chromeTheme`: a sheet inherits the
/// environment of the view its `.sheet(…)` hangs from, and `ContentView` presents
/// this one before its `.chromeThemed(_:)` injection, so the theme is already an
/// ancestor. The dialog stands on `bgPanel` under a `dialogEdgeStripHeight` title
/// strip; each pane has a `panelHeaderHeight` header; every rule is a `hairline`.
///
/// The content does not clip itself to a corner radius: a sheet's frame is the
/// system's, and clipping inside it would only expose the sheet's own ground at
/// the corners. The sheet keeps the system's corners.
struct CommitDialogView: View {
    @ObservedObject var model: CommitDialogModel
    /// Shared preferences, for the diff panel's font size.
    @ObservedObject var settings: SettingsStore = SettingsStore()

    /// Run the commit. `PisakaApp` performs it under its gates and closes the
    /// sheet on success; a failure leaves it open with git's stderr showing in
    /// `model.errorMessage`. The `Int` is `model.currentRequestGeneration`, read
    /// **synchronously in the button's action** before the `Task` hop: the handler
    /// runs a later main-actor turn, so a pin taken there would compare the token
    /// against itself and never catch a folder switch made in between.
    var onCommit: (Int) async -> Void = { _ in }
    /// Dismiss with no side effects (Cancel, Esc).
    var onCancel: () -> Void = {}

    /// Whether the two-field author editor is up.
    @State private var isEditingAuthor = false

    /// The interface zone's metrics, inherited from the window that presents this
    /// sheet — a sheet is a descendant of its presenter for environment purposes,
    /// so `ContentView`'s root injection reaches here with nothing threaded.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited the same way as the metrics above.
    @Environment(\.chromeTheme) private var theme

    /// Whether the message editor holds focus — drives the field box's accent
    /// border.
    @FocusState private var isMessageFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if isAwaitingLoad && model.files.isEmpty {
                loading
            } else {
                HSplitView {
                    fileList
                        .frame(
                            minWidth: metrics.scaled(220),
                            idealWidth: metrics.scaled(280),
                            maxWidth: metrics.scaled(420)
                        )
                    diffPanel
                        .frame(minWidth: metrics.scaled(380), maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
            hairline(horizontal: true)
            bottomSection
        }
        .background(theme.color(.bgPanel))
        // The sheet's own size scales with the two panes inside it, so a 200%
        // dialog still holds both at their minimums instead of squeezing the diff
        // out of the split — `InterfaceMetricsTests` pins that composition.
        .frame(
            minWidth: metrics.scaled(900),
            idealWidth: metrics.scaled(1000),
            minHeight: metrics.scaled(560),
            idealHeight: metrics.scaled(640)
        )
        .sheet(isPresented: $isEditingAuthor) {
            AuthorEditorView(identity: model.identity) { name, email in
                Task { await model.setLocalIdentity(name: name, email: email) }
            }
        }
    }

    /// The dialog's title strip. "Commit Changes" is set at `.headline` — the
    /// design's 14 has no place on the chrome's scale (13, 12, 11), so the
    /// nearest step of it is taken rather than a fourth size.
    private var header: some View {
        HStack {
            Text("Commit Changes")
                .font(metrics.scaledFont(.headline, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.panelHeaderPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.dialogEdgeStripHeight))
        .background(theme.color(.bgPanel))
        .overlay(alignment: .bottom) { hairline(horizontal: true) }
    }

    /// A pane's header strip: `panelHeaderHeight`, `bgPanel`, a bottom
    /// `hairline`, and one `textSecondary` line.
    private func paneHeader(_ text: String, truncation: Text.TruncationMode = .tail) -> some View {
        HStack {
            Text(text)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textSecondary))
                .lineLimit(1)
                .truncationMode(truncation)
            Spacer()
        }
        .padding(.horizontal, metrics.scaled(ChromeGeometry.panelHeaderPaddingX))
        .frame(height: metrics.scaled(ChromeGeometry.panelHeaderHeight))
        .background(theme.color(.bgPanel))
        .overlay(alignment: .bottom) { hairline(horizontal: true) }
    }

    /// The one-point rule the dialog draws wherever it used to leave a
    /// `Divider()`: a horizontal rule when `horizontal` is true, a vertical one
    /// otherwise.
    private func hairline(horizontal: Bool) -> some View {
        Rectangle()
            .fill(theme.color(.hairline))
            .frame(
                width: horizontal ? nil : metrics.scaled(ChromeGeometry.hairlineWidth),
                height: horizontal ? metrics.scaled(ChromeGeometry.hairlineWidth) : nil
            )
    }

    private var loading: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left: the files

    private var fileList: some View {
        VStack(spacing: 0) {
            paneHeader(fileCountText)
            if model.files.isEmpty {
                VStack {
                    Spacer()
                    Text("No local changes")
                        .font(metrics.scaledFont(.callout))
                        .foregroundStyle(theme.color(.textSecondary))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // `ScrollViewReader` for one job: when the dialog was opened from a
                // file's Commit… item, the single checked row is the one thing the
                // user came to see, and on a change list taller than the panel it
                // would otherwise sit off screen under a column of unchecked ones —
                // reading as if the preselect had been ignored. A plain ⌘K opening
                // scrolls to its own first row, i.e. nowhere.
                //
                // The scroll is deferred one main-actor turn rather than issued
                // straight from `onAppear`, which is the whole point of it working
                // at all: `onAppear` runs *before* this subtree's first layout pass
                // and the rows live in a `LazyVStack`, which has realized nothing
                // yet — so `scrollTo` is asked for an id that does not exist and is
                // silently dropped. That is exactly the case the scroll exists for
                // (a preselected row far down a list taller than the panel), so
                // issuing it undeferred fails precisely when it matters.
                //
                // It can fire more than once per opening: a *reopen for the same
                // root* takes `prepareForFolderChange`'s no-op path, so the sheet's
                // first frame still draws the previous opening's `files` (the load
                // that empties them runs in a later main-actor turn) and this
                // branch is built, then rebuilt when the fresh list is published.
                // The last firing is the one carrying the fresh `selectedPath`, so
                // the row the user asked for is where the list settles.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.files, id: \.path) { selection in
                                CommitFileRow(
                                    selection: selection,
                                    state: CheckboxState.of(selection),
                                    isSelected: model.selectedPath == selection.path,
                                    isMutable: !model.isRunning,
                                    onSelect: { model.select(path: selection.path) },
                                    onToggle: { model.toggleFile(path: selection.path) }
                                )
                            }
                        }
                        .padding(.vertical, metrics.scaled(2))
                    }
                    .onAppear {
                        guard let path = model.selectedPath else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(path, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var fileCountText: String {
        let total = model.files.count
        let selected = model.selectedFileCount
        return "\(selected) of \(total) file\(total == 1 ? "" : "s") selected"
    }

    // MARK: - Right: the diff

    @ViewBuilder
    private var diffPanel: some View {
        if let path = model.selectedPath, let selection = model.selection(for: path) {
            VStack(spacing: 0) {
                paneHeader(path, truncation: .middle)
                CommitUnifiedDiffView(
                    lines: model.unifiedLines(for: path),
                    selectedUnits: selection.selectedUnits,
                    // Asked *before* the diff is considered: all three whole-only
                    // categories draw this sentence and no checkbox at all.
                    wholeOnlyMessage: model.wholeOnlyMessage(for: path),
                    fontSize: settings.fontSize,
                    isMutable: !model.isRunning,
                    onToggleUnit: { model.toggleUnit($0, path: path) }
                )
                // The diff preview stands on the code ground, as every pane of
                // code in the chrome does.
                .background(theme.color(.bgEditor))
            }
        } else {
            VStack {
                Spacer()
                Text("Select a file to see its changes")
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(theme.color(.textSecondary))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Bottom: message, author, switches, buttons

    /// The message box and the author line, then — below a `hairline` — the
    /// footer: the two switches, the status sentence and the buttons, sized by
    /// its content.
    private var bottomSection: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: metrics.scaled(8)) {
                Text("Commit Message")
                    .font(metrics.scaledFont(.caption, weight: .semibold))
                    .foregroundStyle(theme.color(.textSecondary))
                messageBox
                authorLine
            }
            .padding(metrics.scaled(10))
            hairline(horizontal: true)
            footer
        }
    }

    /// The commit message, in the shared field box.
    ///
    /// Disabled while the commit runs, like the switches below and for the same
    /// reason: `commit()` pins the message at entry, so text typed mid-run is
    /// not the text git records — and on success the field is cleared and the
    /// sheet closes, so a correction made in that window would vanish with
    /// nothing saying the commit did not carry it. The run is exactly the long
    /// window (hooks, signing) in which noticing a typo is likely.
    ///
    /// The message is written at the *code* font, so the box that holds it is
    /// counted in lines of that font: between `messageMinLines` and
    /// `messageMaxLines` of `messageLineHeight`. A fixed point height followed
    /// no zone at all — the text grew with the code size while the box stood
    /// still — and an interface-scaled one would tie the two zones together.
    /// Only the box's padding is chrome, and it scales. For the same reason it
    /// carries a code `ZoomSurfaceMarker`: a gesture over text drawn at the code
    /// size must grow that size, not the sheet.
    ///
    /// The design pads the text by 12; the box takes the shared field's 10,
    /// because a two-point difference in one drawing is not worth a second
    /// measurement. The editor hides its own scroll background so the box's
    /// `bgEditor` shows through.
    private var messageBox: some View {
        ChromeControlBox(isFocused: isMessageFocused, horizontalPadding: ChromeGeometry.fieldPaddingX) {
            TextEditor(text: $model.message)
                .font(.system(size: settings.fontSize, design: .monospaced))
                .foregroundStyle(theme.color(.textPrimary))
                .scrollContentBackground(.hidden)
                .focused($isMessageFocused)
                .frame(
                    minHeight: messageLineHeight * Self.messageMinLines,
                    maxHeight: messageLineHeight * Self.messageMaxLines
                )
                .disabled(model.isRunning)
                .background(ZoomSurfaceMarker(kind: .code))
        }
    }

    /// The message box's height bounds, in lines of the code font: chosen so the
    /// default code size lands near the fixed 70–120 points the box used to have.
    private static let messageMinLines: CGFloat = 4
    private static let messageMaxLines: CGFloat = 7

    /// One line of the message's code font — the font `TextEditor` draws at —
    /// as the text system lays it out.
    private var messageLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(
            for: NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(8)) {
            switchesLine

            if let message = statusMessage {
                Text(message)
                    .font(metrics.scaledFont(.callout))
                    .foregroundStyle(theme.color(statusIsError ? .statusRed : .textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                // Disabled while the commit runs: dismissing then would fire
                // `onDismiss`, releasing the modal autosave suspension in the
                // middle of git reading the working tree into the temporary index
                // — the very concurrent writer the gate was raised for — while
                // cancelling nothing, since the commit carries on to completion.
                Button("Cancel", action: onCancel)
                    .buttonStyle(.chromeSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                // ⌘Return rather than plain Return: the message field is a
                // multiline editor, where Return has to insert a newline.
                Button("Commit") {
                    let origin = model.currentRequestGeneration
                    Task { await onCommit(origin) }
                }
                .buttonStyle(.chromePrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canCommit)
            }
        }
        .padding(metrics.scaled(10))
    }

    /// The identity git will resolve for this commit — labelled for the role it
    /// will actually play.
    ///
    /// **Under Amend it is the *committer*, not the author.** `git commit --amend`
    /// without `--reset-author` keeps the amended commit's author name, email and
    /// date and replaces only the committer, so calling this line "Author" while
    /// Amend is ticked states something git will not record — the exact failure the
    /// per-field source labelling exists to prevent, only with the screen
    /// confidently wrong rather than silent. It matters in both directions: a user
    /// who fixes their local identity and amends to re-attribute the commit does
    /// not re-attribute it, and one amending someone else's commit is told they
    /// are the author when the original name survives. The identity is still
    /// required (and still blocks the commit when unset) — git needs a committer
    /// either way. Showing the *amended commit's* author would need a further
    /// `git log -1` read; naming the role correctly needs none, and is what stops
    /// the line from lying.
    private var authorLine: some View {
        HStack(spacing: metrics.scaled(6)) {
            Text(model.amend ? "Committer:" : "Author:")
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.textSecondary))
            // An incomplete identity is red *and* blocks the commit (`CommitGate`
            // reports `.identityIncomplete`): the whole point of showing the author
            // is that a repository never commits under a name nobody looked at.
            Text(model.identity.signature)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(model.identity.isComplete ? .textPrimary : .statusRed))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.amend {
                Text("(amend keeps the original author)")
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
            }
            // Also disabled while the commit runs, and here it is not merely a
            // display inconsistency: `setLocalIdentity` runs `git config --local`
            // on the *same serial queue* as the commit's own steps, so a write
            // landing between them decides by scheduling which identity the
            // commit records — the one thing this line exists to make certain.
            // Disabled while a previous save is still in flight for the mirror
            // reason: the editor dismisses on Save, so a second one opened in that
            // window would be seeded from the identity being replaced. The commit
            // itself is blocked for that same window by `CommitGate`, not here.
            // A plain button with an `accent` label rather than the platform's
            // link style, whose colour is the system accent, not the role.
            Button("Edit…") { isEditingAuthor = true }
                .buttonStyle(.plain)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(theme.color(.accent))
                .disabled(model.root == nil || model.isRunning || model.isWritingIdentity)
            Spacer()
        }
    }

    private var switchesLine: some View {
        HStack(spacing: metrics.scaled(16)) {
            // Amend moves the message field with it, so it goes through the model
            // rather than writing the stored property.
            ChromeCheckbox(
                state: model.amend ? .on : .off,
                label: "Amend",
                title: "Amend"
            ) { model.setAmend(!model.amend) }
            // Pinned at entry like the rest of the intent, and `setAmend` also
            // rewrites the message field — so a mid-run toggle would visibly
            // change the composed message while the commit records neither.
            .disabled(model.isRunning)
            // Also disabled while the commit runs: `commit()` pins this at entry
            // with the rest of the intent, so a toggle made mid-run would change
            // nothing while appearing to — and the control it appears to change
            // decides whether the result is published to a remote.
            ChromeCheckbox(
                state: model.pushAfterCommit ? .on : .off,
                label: "Push after commit",
                title: "Push after commit"
            ) { model.pushAfterCommit.toggle() }
            .disabled(model.pushPlan?.isAvailable != true || model.isRunning)
            if let text = pushText {
                Text(text)
                    .font(metrics.scaledFont(.caption))
                    .foregroundStyle(theme.color(.textSecondary))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var pushText: String? {
        switch model.pushPlan {
        case let .push(upstream): return "to \(upstream)"
        case let .setUpstream(remote, branch): return "to \(remote)/\(branch) (new upstream)"
        case let .unavailable(reason): return reason.message
        case nil: return nil
        }
    }

    /// Whether the repository has not been read yet.
    ///
    /// `isLoading` alone is not that question: `openCommitDialog` presents the
    /// sheet and *then* spawns the load, so the first frame renders with it still
    /// `false` and nothing loaded. A read that actually failed publishes
    /// `errorMessage` (and leaves `context` nil), which is what keeps this from
    /// spinning forever on a folder that is not a repository.
    private var isAwaitingLoad: Bool {
        model.errorMessage == nil && (model.isLoading || model.context == nil)
    }

    /// What to say under the switches: the last failure if there is one, else the
    /// gate's reason for the Commit button being disabled.
    ///
    /// The gate is deliberately silent until the repository has been read.
    /// `CommitGate` reports `.noRepository` from a `nil` context, which during a
    /// load means "not read yet" — so without this the sheet asserted "This folder
    /// is not a git repository." for the whole load, next to its own spinner, for
    /// as long as reading every changed file takes. A folder that genuinely is not
    /// one arrives as `errorMessage` above and is reported there.
    private var statusMessage: String? {
        if let error = model.errorMessage { return error }
        guard !isAwaitingLoad else { return nil }
        return model.block?.message
    }

    private var statusIsError: Bool { model.errorMessage != nil }
}

/// One row of the commit dialog's file list: the three-state checkbox, the
/// status-tinted file icon, two lines — the name, then its directory — and the
/// one-letter status badge shared with the Local Changes panel.
///
/// The letter, its colour and its spoken name are Core's one answer
/// (`FileStatus.letter`, `ChromeColorRole.changedFileRole(for:)`,
/// `FileStatus.spokenName`) — the same three the Local Changes panel and the Log's
/// detail pane read.
///
/// The row states no height: two lines plus its padding size it, so it grows
/// with the interface scale instead of clipping its second line.
///
/// The background is `TreeRowState`'s precedence — selected in a key window
/// `accentTintStrong`, selected in one that is not `selectionInactive`, the
/// pointer inside `hoverTint`. The design's one mock draws the selected row in
/// `accentTint` and cannot show the other two states, so the established
/// precedence the tree already paints wins.
///
/// The checkbox is three-state only where a partial selection can exist: a file
/// with no line units — binary, deleted, or differing only in line endings — is
/// checked or unchecked and never mixed, which is `CheckboxState.of(_:)`'s rule
/// rather than this view's.
private struct CommitFileRow: View {
    let selection: CommitFileSelection
    let state: CheckboxState
    let isSelected: Bool
    /// Whether the checkbox may still be changed — false while a commit runs.
    /// `commit()` pins the whole selection at entry, so a file unchecked mid-run
    /// is still committed while its checkbox visibly clears.
    let isMutable: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void

    @State private var isHovering = false

    /// The interface zone's metrics, inherited from the sheet's root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the sheet's root.
    @Environment(\.chromeTheme) private var theme
    /// Whether the window is key — the unfocused selection is a different role.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let status = selection.file.status
        let statusColor = theme.color(ChromeColorRole.changedFileRole(for: status))
        let icon = FileIcon(
            for: DirectoryEntry(url: URL(fileURLWithPath: selection.path), isDirectory: false)
        )
        let name = (selection.path as NSString).lastPathComponent
        let directory = (selection.path as NSString).deletingLastPathComponent
        HStack(spacing: metrics.scaled(6)) {
            ChromeCheckbox(
                state: ChromeCheckbox.State(state),
                label: "Include \(name) in the commit",
                action: onToggle
            )
            .help("Include this file in the commit")
            .disabled(!isMutable)
            // The glyph's size is its own, not inherited: the row carries no
            // container font, so without this it draws at the system default and
            // stands still while the name and status letter grow with the scale.
            // `.callout`, as `ChangedFileRow`'s icon in Local Changes.
            Image(systemName: icon.symbolName)
                .font(metrics.scaledFont(.callout))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(metrics.scaledFont(.body))
                    .foregroundStyle(theme.color(.textPrimary))
                    .truncationMode(.middle)
                if !directory.isEmpty {
                    Text(directory)
                        .font(metrics.scaledFont(.caption))
                        .foregroundStyle(theme.color(.textSecondary))
                        .truncationMode(.head)
                }
            }
            .lineLimit(1)
            Spacer(minLength: metrics.scaled(4))
            Text(status.letter)
                .font(metrics.scaledFont(.callout, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .accessibilityValue(status.spokenName)
        }
        .padding(.horizontal, metrics.scaled(6))
        .padding(.vertical, metrics.scaled(3))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    /// The row's wash, asked of `TreeRowState` (a file row is never a drop
    /// target) and painted through `TreeRowBackground.color(for:resolving:)` —
    /// the tree's one state-to-colour mapping, called rather than copied, so the
    /// day the tree's answer changes this row changes with it.
    private var background: Color {
        let rowState = TreeRowState.state(
            isSelected: isSelected,
            isWindowKey: controlActiveState == .key,
            isHovering: isHovering,
            isDropTarget: false
        )
        return TreeRowBackground.color(for: rowState, resolving: theme.color)
    }
}

/// The author editor: two fields whose Save writes the repository's **local**
/// config (`git config --local user.name/user.email`) and re-reads the author line
/// from git, so what the dialog then shows is what git resolved rather than what
/// was typed. The global config is never touched — a commit dialog is the wrong
/// place to change a machine-wide identity, as `CommitIdentity` records.
private struct AuthorEditorView: View {
    let identity: CommitIdentity
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The interface zone's metrics — inherited through the commit sheet that
    /// presents this one, two levels down from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited the same way.
    @Environment(\.chromeTheme) private var theme
    @State private var name: String
    @State private var email: String
    @FocusState private var focusedField: Field?

    /// The two fields, for the shared field's focus ring.
    private enum Field: Hashable {
        case name
        case email
    }

    init(identity: CommitIdentity, onSave: @escaping (String, String) -> Void) {
        self.identity = identity
        self.onSave = onSave
        _name = State(initialValue: identity.name)
        _email = State(initialValue: identity.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.scaled(10)) {
            Text("Commit Author")
                .font(metrics.scaledFont(.headline, weight: .semibold))
                .foregroundStyle(theme.color(.textPrimary))
            Text("Saved to this repository's local config only — your global git identity is left unchanged.")
                .font(metrics.scaledFont(.caption))
                .foregroundStyle(theme.color(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: metrics.scaled(10)) {
                ChromeThemedTextField(
                    title: "Name",
                    text: $name,
                    focus: $focusedField,
                    focusedEquals: .name,
                    textStyle: .body
                )
                ChromeThemedTextField(
                    title: "Email",
                    text: $email,
                    focus: $focusedField,
                    focusedEquals: .email,
                    textStyle: .body
                )
            }
            .frame(width: metrics.scaled(360))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.chromeSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        email.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .buttonStyle(.chromePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!isUsable)
            }
        }
        .font(metrics.scaledFont(.body))
        .padding(metrics.scaled(16))
        // Wider than the 360pt fields inside it at every scale, so the two fields
        // never touch the sheet's edge.
        .frame(minWidth: metrics.scaled(400))
        .background(theme.color(.bgPanel))
    }

    /// Both fields must be non-blank: writing a blank one would leave the identity
    /// incomplete, which is the state the editor exists to get out of.
    private var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#endif
