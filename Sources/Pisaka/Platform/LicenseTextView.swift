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
    /// `InterfaceMetrics.font(.caption)`: it is the largest reading surface in
    /// Preferences, and a license pinned at 11pt inside a window scaled to 200%
    /// would be the one island left in the interface zone. Defaulting to `nil`
    /// rather than to a number keeps the two platforms' resting appearance the
    /// property of the platform, not of this parameter.
    var pointSize: Double?

    var body: some View {
        Representable(text: text, pointSize: pointSize)
    }
}

#if os(macOS)
import AppKit

extension LicenseTextView {
    fileprivate struct Representable: NSViewRepresentable {
        let text: String
        let pointSize: Double?

        /// The size to draw at: the interface zone's, or the one this pane used
        /// before there was a zone.
        private var resolvedPointSize: CGFloat {
            pointSize.map { CGFloat($0) } ?? NSFont.smallSystemFontSize
        }

        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false

            guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 12, height: 12)
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
            // Selecting a different dependency reuses this view, so guard on the
            // content: re-setting an unchanged string would drop the user's
            // selection and scroll position for nothing. A zoom step changes the
            // size without changing the text, so that is a second reason to
            // re-apply — and the *only* one that must not scroll back to the top,
            // since the user is reading where they are.
            let isNewDocument = textView.string != text
            guard isNewDocument || textView.font?.pointSize != resolvedPointSize else { return }
            apply(text: text, to: textView)
            if isNewDocument { textView.scroll(.zero) }
        }

        private func apply(text: String, to textView: NSTextView) {
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: resolvedPointSize, weight: .regular)
            textView.textColor = .labelColor
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

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = .clear
            textView.alwaysBounceVertical = true
            textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
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
