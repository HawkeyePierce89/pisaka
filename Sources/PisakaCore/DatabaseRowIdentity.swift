import Foundation

/// One primary-key column, located in the answer the grid is drawn from.
///
/// A name **and** a position, because both halves are needed and neither can be
/// derived from the other: the name is what the `UPDATE … WHERE` quotes, and the
/// index is where that column's value sits in the row on screen. The index is
/// into the **answered** columns (`SELECT *`'s), not into the schema's — see
/// `DatabaseRowIdentity` for why the two are not the same list.
public struct DatabaseKeyColumn: Equatable, Hashable, Sendable {
    /// The column name, spelled as the schema declares it — the spelling the
    /// `WHERE` clause quotes.
    public var name: String
    /// Where the column's value sits in an answered row, zero-based.
    public var resultIndex: Int

    public init(name: String, resultIndex: Int) {
        self.name = name
        self.resultIndex = resultIndex
    }
}

/// Why a table's rows cannot be addressed one at a time.
///
/// Each case names the fact that is missing, not a sentence: the sentences are
/// `DatabaseEditRefusal`'s, so the surface has one place to read them from and
/// this engine stays a decision rather than a phrasebook.
public enum DatabaseRowIdentityGap: Equatable, Hashable, Sendable {
    /// The entry is a view. A view's rows are computed, so there is nothing for
    /// an `UPDATE` to name — not even in the cases SQLite would accept through an
    /// `INSTEAD OF` trigger, which is a schema author's write path and not one
    /// this viewer may invent.
    case view
    /// The table can be addressed by no rowid alias and declares no primary key
    /// at all — the honest "there is no way to name this row".
    case noRowIdentity
    /// A key column is not among the columns the page answered, so its value is
    /// not on screen and cannot be put in a `WHERE`. A hidden (generated) key
    /// column reaches here, which is the correct answer for it.
    case keyColumnNotAnswered(name: String)
    /// A key column's name matches more than one answered column, so which of
    /// them holds the key is a guess. Refused rather than guessed.
    case keyColumnAmbiguous(name: String)
}

/// How the rows of one table are addressed by an `UPDATE … WHERE`.
///
/// The viewer's whole write path rests on naming **exactly one row** from a page
/// the reader is looking at, and SQLite offers two ways to do it. Which of the
/// two applies is a fact about the table, and this is where that fact is decided:
///
/// - **`rowid`** — an ordinary table has an implicit 64-bit key readable under
///   one of three spellings. The page carries it as a trailing result column and
///   the `WHERE` names it. This is the case for almost every table.
/// - **`primaryKey`** — a `WITHOUT ROWID` table has no such column, so its rows
///   are named by their declared primary key, every column of it, in key order.
/// - **`unavailable`** — a view, a table with neither, or a table whose key the
///   answer does not carry. A refusal, never a guess.
///
/// **Two rules make this less obvious than it looks.**
///
/// *Shadowing.* `rowid`, `_rowid_` and `oid` are the same column — until the
/// table declares a column of its own by one of those names, at which point that
/// spelling resolves to the **declared** column while the other two still answer
/// the true rowid. So the alias is not a constant: it is the first spelling the
/// table does not shadow, and a table shadowing all three falls back to its
/// primary key.
///
/// *Schema ordinals are not result ordinals.* The schema is read through
/// `PRAGMA table_xinfo`, which lists hidden columns — a virtual table's, and both
/// flavours of generated column — that `SELECT *` does not answer. The two lists
/// therefore diverge, and a key column is located in the row on screen **by
/// name**, case-insensitively, never by position. No unique match is a refusal:
/// a positional map that guessed would put the wrong column in a `WHERE`, which
/// is how an edit lands on the wrong row.
public enum DatabaseRowIdentity: Equatable, Hashable, Sendable {
    /// The table is addressable by rowid, under this spelling.
    case rowid(alias: DatabaseRowIdAlias)
    /// The table is addressable by its declared primary key: these columns, in
    /// key order, at these positions in an answered row.
    case primaryKey(columns: [DatabaseKeyColumn])
    /// The table's rows cannot be addressed one at a time, for this reason.
    case unavailable(DatabaseRowIdentityGap)

    // MARK: - Resolving

    /// The alias to probe with, or `nil` when the table shadows all three.
    ///
    /// Asked **before** the probe, because probing a shadowed spelling asks about
    /// the declared column instead: a `WITHOUT ROWID` table with a column named
    /// `rowid` answers `SELECT rowid FROM t LIMIT 0` perfectly happily, and a
    /// probe that read that as "rowid-addressable" would then compose pages
    /// against `_rowid_`, which does not exist there — a table that refuses to
    /// load at all, from a spelling nobody chose.
    ///
    /// Matching is case-insensitive, because SQLite's identifier comparison is.
    public static func probeAlias(columns: [DatabaseColumn]) -> DatabaseRowIdAlias? {
        let declared = Set(columns.map { $0.name.lowercased() })
        return DatabaseRowIdAlias.allCases.first { !declared.contains($0.rawValue.lowercased()) }
    }

    /// How rows of this entry are addressed.
    ///
    /// - Parameters:
    ///   - kind: table or view; a view is refused outright.
    ///   - columns: the schema, as `PRAGMA table_xinfo` described it — hidden
    ///     columns and all.
    ///   - answeredColumns: the names the page statement answered, in order,
    ///     **without** any trailing identity column. This is the list a key
    ///     column is located in.
    ///   - hasRowId: what the probe said, and it must be the probe composed for
    ///     `probeAlias(columns:)` — a probe of a shadowed spelling answers about
    ///     a different column. `false` for a table that shadows all three, since
    ///     there is then no spelling left to ask with.
    public static func resolve(
        kind: DatabaseTableEntry.Kind,
        columns: [DatabaseColumn],
        answeredColumns: [String],
        hasRowId: Bool
    ) -> DatabaseRowIdentity {
        guard kind == .table else { return .unavailable(.view) }
        if hasRowId, let alias = probeAlias(columns: columns) {
            return .rowid(alias: alias)
        }
        return primaryKeyIdentity(columns: columns, answeredColumns: answeredColumns)
    }

    /// The primary-key strategy, or the gap that stops it.
    ///
    /// The key columns are taken in **key order** (`primaryKeyPosition`), not in
    /// declaration order: the order is what a composite key's `WHERE` is built
    /// in, and it is carried as an ordinal by `DatabaseColumn` precisely so it
    /// need not be re-derived from a second pragma here.
    private static func primaryKeyIdentity(
        columns: [DatabaseColumn],
        answeredColumns: [String]
    ) -> DatabaseRowIdentity {
        let keyColumns = columns
            .filter { $0.primaryKeyPosition != nil }
            .sorted { ($0.primaryKeyPosition ?? 0) < ($1.primaryKeyPosition ?? 0) }
        guard !keyColumns.isEmpty else { return .unavailable(.noRowIdentity) }

        var located: [DatabaseKeyColumn] = []
        for column in keyColumns {
            switch answeredIndex(of: column.name, in: answeredColumns) {
            case .found(let index):
                located.append(DatabaseKeyColumn(name: column.name, resultIndex: index))
            case .missing:
                return .unavailable(.keyColumnNotAnswered(name: column.name))
            case .ambiguous:
                return .unavailable(.keyColumnAmbiguous(name: column.name))
            }
        }
        return .primaryKey(columns: located)
    }

    /// What looking a name up among the answered columns found.
    ///
    /// Three outcomes rather than an optional, because "two columns spell this
    /// name" is not the same failure as "no column does" and the two are refused
    /// with different sentences.
    enum AnsweredMatch: Equatable {
        case found(Int)
        case missing
        case ambiguous
    }

    /// Locate `name` among `answeredColumns`, case-insensitively.
    ///
    /// The one lookup, used by the key resolution here and — in the planner — by
    /// the question of which schema column a grid column *is*. Stated once so the
    /// two cannot disagree about what "the same column" means.
    static func answeredIndex(of name: String, in answeredColumns: [String]) -> AnsweredMatch {
        let wanted = name.lowercased()
        var found: Int?
        for (index, answered) in answeredColumns.enumerated() where answered.lowercased() == wanted {
            if found != nil { return .ambiguous }
            found = index
        }
        guard let found else { return .missing }
        return .found(found)
    }
}
