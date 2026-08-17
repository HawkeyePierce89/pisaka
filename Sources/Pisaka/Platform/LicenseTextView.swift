#if os(macOS) || os(iOS)
import SwiftUI

/// A read-only, selectable, scrolling pane for one verbatim license text — the
/// body of both Acknowledgements screens.
///
/// Lives in the non-gated `Platform/` layer because both screens need it and the
/// only per-platform part is which concrete text view backs it. It makes no
/// decisions about *what* is shown: it takes a `String` and renders all of it.
///
/// **Why this is TextKit and not `ScrollView { Text(...) }`.** The texts here are
/// not label-sized. `libgit2.txt` is 66 KB / 1,323 lines, and `tree-sitter.txt`
/// is 22 KB; at caption-monospaced on a phone width, wrapping puts the laid-out
/// content tens of thousands of points tall. A SwiftUI `Text` is a single view
/// with a single intrinsic size, so it lays the whole string out synchronously on
/// the main thread when the pane appears — a visible hitch on the one screen this
/// feature adds — and content that tall is in the range where the tail can be
/// clipped rather than scrolled to. A silently truncated license is precisely the
/// failure the Acknowledgements screens exist to prevent, and the view layer is
/// untested by convention, so nothing here would catch it. `NSTextView`/
/// `UITextView` generate glyphs lazily for the visible range instead, which makes
/// both problems structurally impossible rather than merely unlikely.
///
/// Selection is enabled and editing is not: copying a license out of the app is a
/// legitimate thing to want, and unlike a `LazyVStack` of chunked `Text`s a single
/// text view keeps selection continuous across the whole document.
struct LicenseTextView: View {
    let text: String

    /// The point size to draw the text at, or `nil` for the platform's small
    /// system size — what it drew before the interface zoom zone existed, and what
    /// every iOS caller still passes.
    ///
    /// Present so the macOS Acknowledgements pane can hand down
    /// `InterfaceMetrics.font(.subheadline)` — whose base of 11 is
    /// `NSFont.smallSystemFontSize`, so 100% still draws what it always did. It is
    /// the largest reading surface in Preferences, and a license pinned at 11pt
    /// inside a window scaled to 200% would be the one island left in the
    /// interface zone. Defaulting to `nil`
    /// rather than to a number keeps the two platforms' resting appearance the
    /// property of the platform, not of this parameter.
    var pointSize: Double?

    /// The margin between the pane's edge and the text, or `nil` for the
    /// platform's own — 12 on macOS, 16 on iOS, the values this pane used before
    /// the interface zoom zone existed.
    ///
    /// Separate from `pointSize` because TextKit takes the two through different
    /// properties, and scaled for the same reason the size is: the header
    /// directly above this pane pads by `metrics.scaled(12)`, so a fixed inset
    /// here would put the license text out of line with its own header at
    /// anything but 100%, and leave the pane's internal margin as the one
    /// unscaled thing in a window scaled to 200%.
    var inset: Double?

    var body: some View {
        Representable(text: text, pointSize: pointSize, inset: inset)
    }
}

#if os(macOS)
import AppKit

extension LicenseTextView {
    fileprivate struct Representable: NSViewRepresentable {
        let text: String
        let pointSize: Double?
        let inset: Double?

        /// The size to draw at: the interface zone's, or the one this pane used
        /// before there was a zone.
        private var resolvedPointSize: CGFloat {
            pointSize.map { CGFloat($0) } ?? NSFont.smallSystemFontSize
        }

        /// The margin to draw with: the interface zone's, or the 12 this pane
        /// used before there was a zone.
        private var resolvedInset: NSSize {
            let value = inset.map { CGFloat($0) } ?? 12
            return NSSize(width: value, height: value)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false

            guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = resolvedInset
            // The pane wraps to its width and scrolls only vertically; a license is
            // hard-wrapped prose, so horizontal scrolling would be noise.
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            // Non-contiguous layout is what makes the 66 KB case cheap: it lets the
            // layout manager lay out the visible range and estimate the rest,
            // instead of walking the whole document up front.
            textView.layoutManager?.allowsNonContiguousLayout = true
            apply(text: text, to: textView)
            return scrollView
        }

        func updateNSView(_ scrollView: NSScrollView, context: Context) {
            guard let textView = scrollView.documentView as? NSTextView else { return }
            // The margin travels with the size — both change on a zoom step and
            // neither touches the text — and is set before the content guard
            // below so it lands whether or not the selection also changed.
            // Guarded so an unrelated re-evaluation does not invalidate layout.
            if textView.textContainerInset != resolvedInset {
                textView.textContainerInset = resolvedInset
            }
            // Selecting a different dependency reuses this view, so guard on the
            // content: re-setting an unchanged string would drop the user's
            // selection and scroll position for nothing.
            if textView.string != text {
                apply(text: text, to: textView)
                textView.scroll(.zero)
                return
            }
            // A zoom step changes the size without changing the text, and that is
            // the path that must *not* disturb where the user is reading — so it
            // sets the font alone. Re-entering `apply` here would re-assign the
            // whole 66 KB string on every step, which drops the selection and the
            // scroll position exactly as the guard above exists to prevent.
            guard textView.font?.pointSize != resolvedPointSize else { return }
            textView.font = font
        }

        private func apply(text: String, to textView: NSTextView) {
            textView.string = text
            textView.font = font
            textView.textColor = .labelColor
        }

        private var font: NSFont {
            .monospacedSystemFont(ofSize: resolvedPointSize, weight: .regular)
        }
    }
}
#elseif os(iOS)
import UIKit

extension LicenseTextView {
    fileprivate struct Representable: UIViewRepresentable {
        let text: String
        /// Always `nil` on this platform — no iOS screen passes one, so the base
        /// size stays `UIFont.smallSystemFontSize` and Dynamic Type scales it, as
        /// it always has. Present so the two halves take the same value.
        let pointSize: Double?
        /// Always `nil` on this platform too — there is no interface zoom zone
        /// here, so the margin stays the 16 it has always been. Present for the
        /// same reason `pointSize` is: the two halves take the same value.
        let inset: Double?

        private var resolvedInset: CGFloat { inset.map { CGFloat($0) } ?? 16 }

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = .clear
            textView.alwaysBounceVertical = true
            textView.textContainerInset = UIEdgeInsets(
                top: resolvedInset, left: resolvedInset, bottom: resolvedInset, right: resolvedInset
            )
            // `UITextView` insets its container by 5pt on each side on top of
            // `textContainerInset`; zeroing it keeps the left margin equal to the
            // header's above it.
            textView.textContainer.lineFragmentPadding = 0
            apply(text: text, to: textView)
            return textView
        }

        func updateUIView(_ textView: UITextView, context: Context) {
            guard textView.text != text else { return }
            apply(text: text, to: textView)
        }

        private func apply(text: String, to textView: UITextView) {
            textView.text = text
            // Dynamic Type: `adjustsFontForContentSizeCategory` only tracks fonts
            // vended by `UIFontMetrics`, so the monospaced face is scaled through
            // the caption metric rather than pinned at a fixed point size — the
            // `.system(.caption, design: .monospaced)` this replaced scaled too.
            let base = UIFont.monospacedSystemFont(
                ofSize: pointSize.map { CGFloat($0) } ?? UIFont.smallSystemFontSize,
                weight: .regular
            )
            textView.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base)
            textView.adjustsFontForContentSizeCategory = true
            textView.textColor = .label
        }
    }
}
#endif
#endif
