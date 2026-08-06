#if os(macOS)
import SwiftUI
import AppKit
import SwiftTerm

/// The embedded terminal panel: a tab bar above the active session's terminal
/// view. Hosting one persistent `LocalProcessTerminalView` per session means
/// switching tabs only swaps which view is on screen, never restarting a shell.
struct TerminalPanelView: View {
    @ObservedObject var model: TerminalSessionsModel

    /// The current project folder, used only when creating a *new* session — an
    /// existing session keeps the directory it was started in.
    let projectRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let active = model.activeSession {
                TerminalHostView(session: active, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color(nsColor: .textBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 120)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.sessions) { session in
                        tab(for: session)
                    }
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            Button {
                model.newSession(projectRoot: projectRoot)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New terminal")
            .padding(.trailing, 6)
        }
        .padding(.vertical, 4)
        .frame(height: 28)
    }

    private func tab(for session: TerminalSession) -> some View {
        let isActive = session.id == model.activeID
        return HStack(spacing: 4) {
            Text(session.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Button {
                model.close(id: session.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("Close terminal")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isActive ? Color(nsColor: .selectedControlColor) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { model.activate(id: session.id) }
    }
}

/// The host's container view, subclassed purely for the appearance hook: AppKit
/// calls `viewDidChangeEffectiveAppearance()` whenever the view's effective
/// appearance changes, which covers *both* a system light/dark switch and a theme
/// forced through `ThemePreference` (SwiftUI applies `.preferredColorScheme` to the
/// window, so the hosted AppKit views' `effectiveAppearance` changes with it).
/// Keying off the view rather than observing `SettingsStore` is what lets one
/// mechanism cover both cases.
///
/// It adds nothing else: the swap-on-tab-change and focus-on-install semantics of
/// `TerminalHostView` are unchanged by its introduction.
private final class TerminalContainerView: NSView {
    var onAppearanceChange: ((NSAppearance) -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?(effectiveAppearance)
    }
}

/// Hosts a single session's `LocalProcessTerminalView`. SwiftTerm handles keyboard
/// capture and PTY resize on the view itself, so this only places the active
/// session's view in the hierarchy and makes it first responder so it has focus.
private struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession

    /// The sessions model, used only to apply the terminal theme: the recolor goes
    /// to *every* live session, not just the hosted one, because an inactive
    /// session's view is out of the hierarchy and would otherwise never learn about
    /// the change (it would surface the old theme on the next tab switch).
    let model: TerminalSessionsModel

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.onAppearanceChange = { [model] appearance in
            model.applyTheme(for: appearance)
        }
        install(session.terminalView, in: container)
        applyTheme(from: container)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        // Swap to the active session's view only when it changed (a tab switch), so
        // re-renders don't churn the hierarchy or steal focus mid-typing.
        let terminalView = session.terminalView
        guard terminalView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        install(terminalView, in: container)
        applyTheme(from: container)
    }

    /// Recolors the sessions for the container's current appearance on mount and on
    /// a tab change: `viewDidChangeEffectiveAppearance()` is not guaranteed to fire
    /// when a view is inserted, and the panel may have been hidden (with its
    /// sessions still alive) while the theme changed.
    ///
    /// Deliberately *not* part of `install(_:in:)`: this is an idempotent recolor of
    /// already-live views that neither touches the view hierarchy nor the responder
    /// chain, so it can never re-enter the focus path.
    private func applyTheme(from container: TerminalContainerView) {
        model.applyTheme(for: container.effectiveAppearance)
    }

    private func install(_ terminalView: NSView, in container: NSView) {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Focus the freshly installed terminal so keystrokes go to it — but only on
        // an actual install (initial mount or a tab switch), never on every
        // `updateNSView`. The panel re-renders on any SwiftUI invalidation while
        // it's visible, including an editor keystroke republishing `WorkspaceModel`
        // (which re-evaluates the enclosing `ContentView` and so this panel); an
        // unconditional `makeFirstResponder` there would yank focus back from the
        // editor on every keystroke.
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(terminalView)
        }
    }
}

#endif
