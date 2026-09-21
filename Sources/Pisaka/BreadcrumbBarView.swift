#if os(macOS)
import SwiftUI
import PisakaCore

/// The breadcrumb bar above the editor: the open file's path relative to the
/// opened project root (`backend › src › dialogs.service.ts`), or an abbreviated
/// absolute path when it lives outside the root. All the segment computation is
/// `PisakaCore.DisplayPath` — this is display only, so the view stays thin and
/// the rule stays unit-tested. `home` is read here (Core takes it as a
/// parameter, the `TerminalLaunch` precedent).
///
/// A fixed row height (`ChromeGeometry.breadcrumbHeight`) keeps the editor from
/// jumping as the path changes, and middle truncation keeps the file name
/// visible in a narrow window. Rendered inside `ContentView.editorZone`, so both
/// tab orientations get it (in `.horizontal` it lands just under the tab strip).
///
/// **Why it is a file of its own.** It cannot be restyled where it was born: a
/// file gated by `ChromeThemeSourceGatingTests` may name no system semantic
/// colour, and `ContentView.swift` is full of them for surfaces later parts of
/// the sweep will reach. Lifting the strip out is what lets it join the gated
/// set now instead of waiting for its host.
///
/// Like the tab strip, it draws its **own** bottom rule rather than leaving one
/// to its host, so the strip's height and the rule under it cannot disagree.
///
/// The view is split in two — a thin outer view that reads the theme and an
/// inner, `.equatable()` one that draws — for the reason spelled out on
/// `BreadcrumbSegments` below.
struct BreadcrumbBarView: View {
    let fileURL: URL?
    let projectRoot: URL?

    /// The interface zone's metrics, inherited from the window root.
    @Environment(\.interfaceMetrics) private var metrics
    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    var body: some View {
        BreadcrumbSegments(
            fileURL: fileURL,
            projectRoot: projectRoot,
            metrics: metrics,
            appearance: theme.appearance
        )
        .equatable()
    }
}

/// The strip's drawing half, kept `Equatable` on purpose.
///
/// `DisplayPath.components` resolves symlinks (`CanonicalPath.canonical` →
/// `resolvingSymlinksInPath()`, an `lstat` walk per path component) while
/// `ContentView.body` re-evaluates on *every* keystroke: the editor binding
/// routes each edit through `model.updateText`, republishing `openFiles`. Keying
/// this view on `(fileURL, projectRoot)` lets SwiftUI skip the recompute unless
/// the tab or the project root actually changed, so that filesystem work stays
/// off the typing path.
///
/// The interface metrics **and the resolved chrome appearance** are stored
/// properties for the same reason the identity is: equality decides whether
/// SwiftUI re-runs this body at all, so anything that changes what is drawn has
/// to be part of what it compares. The appearance travels exactly as the metrics
/// do — a theme that lived only in the environment would leave the breadcrumb in
/// yesterday's colours until the file changed. The body still *reads* its
/// colours from the environment; the stored appearance is an equality term, not
/// a colour source, which is why this view names no theme type.
private struct BreadcrumbSegments: View, Equatable {
    let fileURL: URL?
    let projectRoot: URL?
    let metrics: InterfaceMetrics
    let appearance: ChromeAppearance

    /// The chrome's colours, inherited from the window root.
    @Environment(\.chromeTheme) private var theme

    /// Written by hand over the four stored properties, so the two things that
    /// are *not* identity — the scale and the appearance — cannot be dropped from
    /// the comparison by a synthesised conformance quietly following a later
    /// added property.
    static func == (lhs: BreadcrumbSegments, rhs: BreadcrumbSegments) -> Bool {
        lhs.fileURL == rhs.fileURL
            && lhs.projectRoot == rhs.projectRoot
            && lhs.metrics == rhs.metrics
            && lhs.appearance == rhs.appearance
    }

    var body: some View {
        text
            .font(metrics.scaledFont(.subheadline))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, metrics.scaled(ChromeGeometry.rowPaddingX))
            .frame(
                maxWidth: .infinity,
                minHeight: metrics.scaled(ChromeGeometry.breadcrumbHeight),
                maxHeight: metrics.scaled(ChromeGeometry.breadcrumbHeight),
                alignment: .leading
            )
            .background(theme.color(.bgPanel))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.color(.hairline))
                    .frame(height: metrics.scaled(ChromeGeometry.hairlineWidth))
            }
    }

    /// The whole path as **one** `Text`, composed by `+`.
    ///
    /// One run rather than an `HStack` of labels because the strip's truncation
    /// is the point: middle truncation over a single string keeps the file name
    /// visible in a narrow window, while a stack would truncate each label on its
    /// own and lose the name first. The final segment — the file itself — takes
    /// `textPrimary`; every leading segment and every separator is
    /// `textSecondary`.
    private var text: Text {
        let components = DisplayPath.components(
            fileURL: fileURL,
            projectRoot: projectRoot,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
        let leading = theme.color(.textSecondary)
        let last = theme.color(.textPrimary)

        return components.enumerated().reduce(Text(verbatim: "")) { composed, pair in
            let separator = pair.offset == 0
                ? Text(verbatim: "")
                : Text(verbatim: " › ").foregroundColor(leading)
            let isLast = pair.offset == components.count - 1
            return composed
                + separator
                + Text(pair.element).foregroundColor(isLast ? last : leading)
        }
    }
}

#endif
