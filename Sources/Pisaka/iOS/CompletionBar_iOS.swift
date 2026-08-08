#if os(iOS)
import UIKit
import PisakaCore

/// The iOS completion surface: a QuickType-style horizontal strip of candidate
/// words installed as the editor's `inputAccessoryView` (Decision 1 of the
/// phase-1 plan).
///
/// **Why a strip and not a popup.** A floating list anchored to the caret is the
/// macOS answer because a pointer can reach it and a mouse never covers the text.
/// On a phone the caret is under a finger, above a keyboard, near a magnifier
/// loupe — a popup there would sit on top of the very code the user is reading,
/// and it would have to fight the keyboard for the same screen. The accessory
/// strip never covers text, never steals a keystroke, and behaves identically
/// with the on-screen and a hardware keyboard, so iPad and iPhone share one
/// surface.
///
/// **Plain UIKit rather than a hosted SwiftUI view.** An input accessory is
/// attached to the *responder*, not to a view hierarchy SwiftUI manages; hosting
/// a SwiftUI view here means owning a `UIHostingController` whose lifecycle no
/// parent controller drives, which is exactly the kind of ownership question this
/// layer should not have.
///
/// Thin view-layer glue, untested by convention: the words shown and their order
/// arrive already ranked and capped from `SymbolIntelligenceProvider`, and the
/// insertion is performed by the coordinator through the same programmatic-edit
/// path auto-pair and indent use.
final class CompletionBar_iOS: UIInputView {

    /// The strip's height. One row of a 15 pt button plus symmetric padding —
    /// deliberately shorter than the system QuickType bar, because it competes
    /// with the keyboard for a phone's remaining vertical space.
    static let barHeight: CGFloat = 40

    /// Called with the tapped word. The coordinator, not this view, decides what
    /// range that word replaces.
    var onSelect: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()

    /// The words currently shown, so an unchanged list costs no view rebuild —
    /// the debounce fires on a settled prefix, and re-typing the same characters
    /// after a backspace produces the same answer.
    private var items: [String] = []

    init() {
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.barHeight),
            inputViewStyle: .keyboard
        )
        // Self-sizing off: the height is fixed and reported through
        // `intrinsicContentSize`, so the strip cannot grow when a long candidate
        // arrives and push the keyboard down mid-sentence.
        allowsSelfSizing = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.barHeight)
    }

    /// Replace the shown words. Returns without touching the view hierarchy when
    /// the list is unchanged, so a debounce that re-answers the same prefix does
    /// not reset the strip's scroll position out from under a reaching thumb.
    func setItems(_ newItems: [String]) {
        guard newItems != items else { return }
        items = newItems

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in newItems {
            stack.addArrangedSubview(makeButton(for: item))
        }
        scrollView.setContentOffset(.zero, animated: false)
    }

    private func makeButton(for item: String) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = item
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 4, leading: 10, bottom: 4, trailing: 10
        )
        // Monospaced, matching the editor: a candidate is a piece of code, and a
        // proportional font makes `l`/`1`/`I` ambiguous in exactly the list where
        // the user is choosing between similar names.
        configuration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                return attributes
            }

        let button = UIButton(configuration: configuration)
        button.addAction(
            UIAction { [weak self] _ in self?.onSelect?(item) },
            for: .touchUpInside
        )
        return button
    }
}
#endif
