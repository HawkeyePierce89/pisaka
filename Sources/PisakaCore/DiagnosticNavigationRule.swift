import Foundation

/// Which way *Next Problem* (⌘') or *Previous Problem* (⌘⇧') steps.
public enum DiagnosticNavigationDirection: Sendable, Equatable {
    case next
    case previous
}

/// Where *Next Problem* / *Previous Problem* puts the caret: one pure answer
/// over the diagnostics the store already holds for a file.
///
/// A **reader over the store**. It is handed the entry's diagnostics as they
/// stand — already shifted across every edit by `DiagnosticShift` — and asks
/// no server anything, so the jump lands where the squiggle is drawn now.
///
/// The rule, in full:
///
/// - **Errors first.** When any error exists only errors are stops, so the
///   command walks what blocks the build and does not stop on every lint
///   warning along the way; with no error, every severity is a stop.
/// - **One stop per start offset.** Diagnostics sharing a start (two servers,
///   or one server naming one construct twice) are one place to go, and the
///   stops are those distinct starts, ascending.
/// - **Strictly past the caret, wrapping.** Next is the first stop strictly
///   after `caret`, else the first stop; previous is the last stop strictly
///   before it, else the last stop. "Strictly" is what makes a caret already
///   sitting on a problem — which is exactly where the previous press left it —
///   move on rather than stay.
/// - **No stops answers `nil`**, which the app turns into a beep.
public enum DiagnosticNavigationRule {

    /// The offset to place the caret at, or `nil` when the file has no
    /// diagnostics at all.
    public static func target(
        diagnostics: [Diagnostic],
        caret: Int,
        direction: DiagnosticNavigationDirection
    ) -> Int? {
        let stops = self.stops(in: diagnostics)
        guard let first = stops.first, let last = stops.last else { return nil }
        switch direction {
        case .next:
            return stops.first(where: { $0 > caret }) ?? first
        case .previous:
            return stops.last(where: { $0 < caret }) ?? last
        }
    }

    /// The distinct, ascending start offsets of the diagnostics that count:
    /// the errors when there are any, every diagnostic otherwise.
    static func stops(in diagnostics: [Diagnostic]) -> [Int] {
        let errors = diagnostics.filter { $0.severity == .error }
        let counted = errors.isEmpty ? diagnostics : errors
        return Set(counted.map(\.range.location)).sorted()
    }
}
