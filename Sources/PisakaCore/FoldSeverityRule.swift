import Foundation

/// The worst severity a folded header line draws.
///
/// The gutter marks one line at a time, but a collapsed block hides many. So a
/// folded header's dot must speak for every line it hides: the worst severity
/// among itself and every line its hidden range collapses. Hidden lines' own
/// entries are left alone — the gutter never draws them — and everything is
/// asked from the store's existing answer, never recomputed off the wire.
///
/// `max` over `DiagnosticSeverity`'s seriousness order is the same expression
/// `DiagnosticStore.worstSeverityPerLine` uses, asked rather than restated.
///
/// A degenerate line table — empty or not anchored at `0` — answers the input
/// unchanged rather than trapping, and a header line outside the table is
/// skipped. Both are the same honest degradation the store's own query uses.
public enum FoldSeverityRule {
    public static func resolved(
        _ perLine: [DiagnosticSeverity?],
        folded state: FoldState,
        lineStarts: [Int]
    ) -> [DiagnosticSeverity?] {
        guard !perLine.isEmpty else { return perLine }
        guard lineStarts.first == 0 else { return perLine }
        guard perLine.count == lineStarts.count else { return perLine }
        guard !state.isEmpty else { return perLine }
        var result = perLine
        for region in state.regions {
            let header = region.headerLine
            guard header >= 0, header < perLine.count else { continue }
            let hidden = region.hiddenRange
            var worst: DiagnosticSeverity? = perLine[header]
            for line in (header + 1)..<lineStarts.count {
                let start = lineStarts[line]
                if start <= hidden.location { continue }
                let separator = start - 1
                if separator < hidden.location { continue }
                if separator >= NSMaxRange(hidden) { break }
                if let severity = perLine[line] {
                    if let current = worst {
                        worst = max(current, severity)
                    } else {
                        worst = severity
                    }
                }
            }
            if let value = worst {
                if let existing = result[header] {
                    result[header] = max(existing, value)
                } else {
                    result[header] = value
                }
            }
        }
        return result
    }
}
