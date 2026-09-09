#if os(macOS)
import PisakaCore
import SwiftUI

/// The preview beside the editor: the one web view, plus the four facts the
/// window forwards into `MarkdownPreviewModel` while it is on screen.
///
/// It draws nothing of its own — no header, no chrome, no placeholder — because
/// everything the user sees is the page, and the page is composed in Core. What
/// this view contributes is the *lifetime*: while a pane exists there is a
/// document being previewed, and when the last one goes the model is cleared.
/// The three ways it goes are the three clears the feature has — a tab that is
/// not Markdown became active, the preference was switched off, and the project
/// folder changed — which is why `onDisappear` is the only place a clear is
/// reached from. It reports the lifetime rather than performing the clear: the
/// tab-orientation switch replaces this pane with another in one update and the
/// two callbacks may arrive in either order, so *which* disappearance is the
/// last one is the controller's count to keep.
///
/// **The facts, and why each is watched separately.** The document (this tab's
/// text, its URL and the project root) re-parses; the appearance (the resolved
/// theme and the code font size) re-writes the shell. They travel on different
/// paths in the model, so they are forwarded through different `onChange`
/// modifiers rather than through one composite — and the appearance is keyed on
/// its *inputs* rather than on the theme itself, because deriving the theme
/// resolves every editor colour against an `NSAppearance` and this body is
/// re-evaluated on every keystroke.
///
/// It is a **code surface** for the pointer: the page's body text and its fenced
/// blocks are sized from `settings.fontSize`, so a zoom gesture over the preview
/// must move the code zone and not the chrome — the LeetCode statement pane's
/// rule, for the same reason and with the same marker.
struct MarkdownPreviewPane: View {

    /// The window's one page. Observed only because `@StateObject`/`@ObservedObject`
    /// is how a reference type is held in SwiftUI — it publishes nothing at all.
    @ObservedObject var controller: MarkdownPreviewController

    /// Theme preference and code font size; the page is recomposed from both, so
    /// changing either re-renders the preview live.
    @ObservedObject var settings: SettingsStore

    /// The tab being previewed. A value, so a keystroke changes it and
    /// `onChange` sees it.
    let file: OpenFile

    /// The opened project's root — the boundary every asset and every link is
    /// checked against, in Core.
    let projectRoot: URL?

    /// The app's own open-a-tab path, handed to the page's navigation delegate.
    let onOpenFile: (URL) -> Void

    /// The appearance the window is actually drawn in, which is what resolves
    /// `ThemePreference.system` — Core may not ask AppKit for it. The LeetCode
    /// statement pane reads it here for the same reason.
    @Environment(\.colorScheme) private var colorScheme

    /// The two inputs the shell is composed from, as a value cheap enough to
    /// compare on every body evaluation. `prefersDark` rather than the theme
    /// itself: the theme is derived from it by reading the editor's whole
    /// palette through an `NSAppearance`, which is work worth doing once per
    /// change rather than once per keystroke.
    private struct AppearanceKey: Equatable {
        var prefersDark: Bool
        var fontSize: Double
    }

    private var appearanceKey: AppearanceKey {
        AppearanceKey(
            prefersDark: MarkdownPreviewTheme.resolved(
                settings.themePreference,
                systemPrefersDark: colorScheme == .dark
            ) == .dark,
            fontSize: settings.fontSize
        )
    }

    var body: some View {
        MarkdownPreviewWebViewRepresentable(page: controller.page)
            // The pointer's answer to "which zone is this?" — see the note above.
            .background(ZoomSurfaceMarker(kind: .code))
            .onAppear {
                controller.openInEditor = onOpenFile
                controller.paneAppeared()
                // The appearance first: it installs the shell, and the body that
                // follows it is held by the page until that document has loaded.
                forwardAppearance()
                forwardDocument()
            }
            // Not `preview(nil,…)` directly: a tab-orientation change replaces
            // this pane with another one in the same update, and the two
            // lifetime callbacks may arrive in either order. The controller
            // counts panes so the document is dropped only when the last one
            // goes — see `MarkdownPreviewController.livePanes`.
            .onDisappear { controller.paneDisappeared() }
            // A keystroke. The model debounces it; nothing here does.
            .onChange(of: file.text) { _ in forwardDocument() }
            // A selection change to another Markdown tab — the pane is not
            // rebuilt for it, so this is what retargets the one page.
            .onChange(of: file.id) { _ in forwardDocument() }
            // The same tab, pointed at another file: a rename or move
            // (`WorkspaceModel.applyRenamePlan`) and a Save As both rewrite a
            // tab's `url` in place, keeping its id and its text — so neither of
            // the two above fires, and without this the preview would go on
            // resolving relative images and links against the file's *old*
            // directory.
            .onChange(of: file.url) { _ in forwardDocument() }
            // A folder switch that leaves this tab selected.
            .onChange(of: projectRoot) { _ in forwardDocument() }
            .onChange(of: appearanceKey) { _ in forwardAppearance() }
    }

    private func forwardDocument() {
        controller.preview(file, projectRoot: projectRoot)
    }

    private func forwardAppearance() {
        let key = appearanceKey
        controller.updateAppearance(
            theme: SyntaxTheme.shared.markdownPreviewTheme(prefersDark: key.prefersDark),
            fontSize: key.fontSize
        )
    }
}
#endif
