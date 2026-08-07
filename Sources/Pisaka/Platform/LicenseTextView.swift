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

    var body: some View {
        Representable(text: text)
    }
}

#if os(macOS)
import AppKit

extension LicenseTextView {
    fileprivate struct Representable: NSViewRepresentable {
        let text: String

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
            // selection and scroll position for nothing.
            guard textView.string != text else { return }
            apply(text: text, to: textView)
            textView.scroll(.zero)
        }

        private func apply(text: String, to textView: NSTextView) {
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textColor = .labelColor
        }
    }
}
#elseif os(iOS)
import UIKit

extension LicenseTextView {
    fileprivate struct Representable: UIViewRepresentable {
        let text: String

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
            let base = UIFont.monospacedSystemFont(ofSize: UIFont.smallSystemFontSize, weight: .regular)
            textView.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base)
            textView.adjustsFontForContentSizeCategory = true
            textView.textColor = .label
        }
    }
}
#endif
#endif
