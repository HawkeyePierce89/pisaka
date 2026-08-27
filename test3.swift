import AppKit
class V: NSView {
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}
