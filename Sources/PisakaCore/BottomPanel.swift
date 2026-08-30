/// Which bottom dock panel is currently shown.
///
/// The Terminal, Git Log, Local Changes, Problems and Usages are bottom dock
/// panels above an always-visible bar; a `BottomPanel?` of `nil` means the panel
/// is hidden. The view layer owns the bar and the panels; this enum plus the pure
/// `toggled(_:selecting:)` helper are the only stateful logic, so they live in
/// Core and are unit-tested (the color-free / pure-logic precedent of
/// `FileIconColor`/`LogFilter`).
public enum BottomPanel: Equatable {
    case terminal
    case log
    case changes
    case problems
    /// Where the identifier under the caret is used — the Find Usages answer.
    ///
    /// A sibling of Problems rather than a mode of it: both are lists of places
    /// in the project, but one is what a server volunteered about the code and
    /// the other is what the user asked about one name, so the two must be
    /// reachable at once (reading a usage list while a diagnostic is on screen is
    /// the ordinary case, not a conflict).
    case usages

    /// Toggle the panel for a clicked/triggered `target`: clicking the panel
    /// that is already shown collapses it (`nil`), otherwise the `target` panel
    /// is shown — so a button or its matching menu command behaves identically.
    public static func toggled(_ current: BottomPanel?, selecting target: BottomPanel) -> BottomPanel? {
        current == target ? nil : target
    }
}
