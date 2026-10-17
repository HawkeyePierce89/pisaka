import Foundation

/// Where *Next Change* / *Previous Change* puts the caret: one pure answer over
/// the hunks the gutter model computed for the live buffer.
///
/// It copies `DiagnosticNavigationRule`'s shape and reuses its direction type,
/// so the two "step through what is marked" commands cannot drift apart in how
/// they wrap. The rule, in full:
///
/// - **One stop per hunk, on a buffer line.** An added or modified hunk stops on
///   its first new-side line; a deleted hunk, which owns no buffer line, stops
///   on its anchor — the line it sits after — and a deletion before line 1
///   stops on line 0. Stops are distinct and ascending (a deletion anchored on
///   the line just before a strip can share no line with it, but the set keeps
///   the rule honest rather than trusting that).
/// - **Strictly past the caret, wrapping.** Next is the first stop strictly
///   after `caretLine`, else the first stop; previous is the last stop strictly
///   before it, else the last stop. A caret already on a stop — where the
///   previous press left it — therefore moves on.
/// - **No stops answers `nil`**, which the app turns into a beep.
public enum ChangeNavigationRule {

    /// The 0-based buffer line to place the caret on, or `nil` when the file has
    /// no hunks at all.
    public static func targetLine(
        hunks: [ChangeHunk],
        caretLine: Int,
        direction: DiagnosticNavigationDirection
    ) -> Int? {
        let stops = self.stops(in: hunks)
        guard let first = stops.first, let last = stops.last else { return nil }
        switch direction {
        case .next:
            return stops.first(where: { $0 > caretLine }) ?? first
        case .previous:
            return stops.last(where: { $0 < caretLine }) ?? last
        }
    }

    /// The distinct, ascending stop lines of `hunks`.
    static func stops(in hunks: [ChangeHunk]) -> [Int] {
        Set(hunks.map { hunk in
            hunk.kind == .deleted ? max(hunk.anchor, 0) : hunk.newLines.lowerBound
        }).sorted()
    }
}
