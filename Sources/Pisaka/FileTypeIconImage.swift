import SwiftUI
import PisakaCore

/// The one way a file-type icon reaches the screen, on both platforms.
///
/// Every surface drawing a file goes through this view: the macOS tree rows and
/// their draft, both tab orientations, the Find in Files headers, the Problems
/// and Usages headers and the Log's changed-file row, and the iOS tree, Local
/// Changes and Log rows. No other source loads a `FileIcons/` asset —
/// `ChromeThemeSourceGatingTests` holds that — so the rendering intent, the
/// aspect rule and the accessibility rule are each stated once.
///
/// Unlike a design glyph, a file-type icon is drawn **original**: its colour is
/// its identity, carried in the asset's own data, so no role can name it and
/// nothing here tints it. That is the theme's third stated exception
/// (`core-theme.md`), and it is why this view takes no `ChromeColorRole`.
///
/// The side is stated at interface scale 1.0. On macOS it follows the interface
/// zone through `interfaceMetrics`; on iOS it follows Dynamic Type through a
/// body-relative `@ScaledMetric`, as the SF Symbol it replaces did.
struct FileTypeIconImage: View {
    let icon: FileTypeIcon
    /// The square the icon is fitted into, in points at scale 1.0 — always the
    /// drawing surface's own statement.
    let side: Double

    #if os(macOS)
    @Environment(\.interfaceMetrics) private var metrics
    #else
    @ScaledMetric(relativeTo: .body) private var dynamicTypeFactor: Double = 1
    #endif

    init(_ icon: FileTypeIcon, side: Double) {
        self.icon = icon
        self.side = side
    }

    /// The drawn side in points, at the platform's own scale.
    private var scaledSide: CGFloat {
        #if os(macOS)
        CGFloat(metrics.pt(side))
        #else
        CGFloat(side * dynamicTypeFactor)
        #endif
    }

    var body: some View {
        // Fitted, never stretched: the frame is square and `scaledToFit` keeps
        // the icon's own aspect inside it. Hidden from accessibility because the
        // row's text already names the file.
        Image(icon.catalogName)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: scaledSide, height: scaledSide)
            .accessibilityHidden(true)
    }
}
