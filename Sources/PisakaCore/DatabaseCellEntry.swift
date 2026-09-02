import Foundation

/// A column's **type affinity** — SQLite's own five, determined from the
/// declared type by SQLite's own five ordered rules.
///
/// The viewer needs this because a grid cell is edited as *text* and stored as a
/// `DatabaseValue`: something has to decide that typing `43` into an `INTEGER`
/// column means the integer 43 while typing it into a `VARCHAR` column means the
/// two characters. SQLite already answers that question for every value it is
/// handed, and it answers it from the declared type alone — so this is a
/// re-implementation of a documented rule, not an invention, and it is tested
/// against the documentation's own example table.
///
/// The rules are **ordered**, and the order is load-bearing rather than
/// incidental: `FLOATING POINT` contains `INT` (inside `POINT`) and therefore has
/// INTEGER affinity, which is surprising enough that SQLite's documentation calls
/// it out and this suite pins it. Restating them as a set of independent tests
/// would quietly get that case wrong.
public enum DatabaseTypeAffinity: Equatable, Hashable, Sendable, CaseIterable {
    /// Rule 1 — the declaration contains `INT`.
    case integer
    /// Rule 2 — it contains `CHAR`, `CLOB` or `TEXT`.
    case text
    /// Rule 3 — it contains `BLOB`, or there is no declaration at all.
    ///
    /// SQLite calls this "no affinity"; the case is named for the rule's own
    /// keyword because that is what `PRAGMA table_xinfo` shows. What matters to
    /// the editor is that such a column stores whatever it is given, unconverted,
    /// which is why it is the one affinity whose typing rule consults the cell's
    /// previous value (see `DatabaseCellEntry`).
    case blob
    /// Rule 4 — it contains `REAL`, `FLOA` or `DOUB`.
    case real
    /// Rule 5 — anything else.
    case numeric

    /// The affinity of a column declared as `declaredType`, which may be empty:
    /// `PRAGMA table_xinfo` answers the empty string for a column declared with
    /// no type at all, and that is rule 3's second half rather than a parse
    /// failure.
    ///
    /// Matching is case-insensitive and by substring, exactly as SQLite's rules
    /// are stated. A declaration of nothing but whitespace is read as no
    /// declaration: SQLite cannot produce one, and the alternative — falling
    /// through five substring tests to NUMERIC — would be a worse answer to a
    /// question that only a malformed schema can ask.
    public init(declaredType: String) {
        let declaration = declaredType.uppercased()
        if declaration.contains("INT") {
            self = .integer
        } else if declaration.contains("CHAR") || declaration.contains("CLOB") || declaration.contains("TEXT") {
            self = .text
        } else if declaration.contains("BLOB") || declaration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .blob
        } else if declaration.contains("REAL") || declaration.contains("FLOA") || declaration.contains("DOUB") {
            self = .real
        } else {
            self = .numeric
        }
    }
}

/// What the reader put in a cell editor, before it is anything a database can
/// store.
///
/// Two cases, and the second one is the whole point of the type: **NULL is a
/// gesture, never a word**. A grid cell holding the text `NULL` and a grid cell
/// holding SQL `NULL` render identically (`DatabaseValue.nullDisplayText` is
/// ink, not identity), so a rule that read the typed string would make the two
/// impossible to tell apart *and* impossible to type: nobody could ever store
/// the four characters. Modelling the gesture as its own case means no caller
/// can reach `.null` by string, and the compiler says so.
///
/// `.typed` carries the text **verbatim**. Nothing is trimmed anywhere in this
/// file: a text column is perfectly entitled to hold `" 42 "`, and a viewer that
/// silently dropped the spaces would be editing a cell the reader did not ask to
/// edit. The consequence — that `" 42 "` in an INTEGER column stores text rather
/// than 42 — is the honest one, and it is what SQLite itself stores if you hand
/// it that string.
public enum DatabaseCellEntry: Equatable, Hashable, Sendable {
    /// What the reader typed, exactly as they typed it. The empty string is a
    /// legitimate entry meaning `text("")` — never NULL.
    case typed(String)
    /// The explicit "Set to NULL" gesture.
    case null

    /// The value to bind for this entry in a column of `affinity` whose cell
    /// currently holds `previousValue`.
    ///
    /// - `.null` is NULL, whatever the column is.
    /// - TEXT affinity stores text, always.
    /// - INTEGER, REAL and NUMERIC store an integer when the whole entry is one,
    ///   a finite real when the whole entry is one, and text otherwise. (REAL's
    ///   documented difference — that it widens integers — is SQLite's to apply
    ///   on store; this layer does not pre-empt it, so what is bound is what was
    ///   typed as closely as the storage classes allow.)
    /// - BLOB, which is "no affinity", is the interesting one: see below.
    ///
    /// **The untyped column.** An ad-hoc database full of columns declared with
    /// no type at all stores whatever it was given, and a whole table may
    /// therefore be integers *by convention alone*. Binding text there — the
    /// obvious choice, since text is what was typed — would silently retype one
    /// cell out from under every query that compares that column, and nothing in
    /// the grid would show it. So the **cell's previous storage class wins when
    /// the entry parses as it**: `43` over the integer `42` stores an integer,
    /// `43` over the text `42` stores text, and `4x` over either stores text. A
    /// previous NULL or blob has no class to preserve and stores text.
    public func value(affinity: DatabaseTypeAffinity, previousValue: DatabaseValue) -> DatabaseValue {
        guard case .typed(let entry) = self else { return .null }

        switch affinity {
        case .text:
            return .text(entry)
        case .integer, .real, .numeric:
            return Self.numericValue(entry) ?? .text(entry)
        case .blob:
            return Self.valuePreservingClass(of: previousValue, entry: entry)
        }
    }

    // MARK: - The two conversions

    /// The entry as a number, preferring an integer, or `nil` when the whole
    /// string is not one.
    ///
    /// An integer too large for `Int64` falls to a real rather than failing —
    /// which is what SQLite does with the same literal — and a real that is not
    /// finite falls through to text, because there is no NULL-free storage class
    /// for an infinity and text is what the reader typed.
    private static func numericValue(_ entry: String) -> DatabaseValue? {
        if let integer = integerValue(entry) { return .integer(integer) }
        if let real = realValue(entry) { return .real(real) }
        return nil
    }

    /// The entry as an `Int64`, or `nil`.
    ///
    /// `Int64.init(_:)` is exactly the rule wanted: the *whole* string, an
    /// optional sign, decimal digits, no whitespace and no other radix — so
    /// `0x10` is text, as it would be to SQLite's own affinity conversion.
    private static func integerValue(_ entry: String) -> Int64? {
        Int64(entry)
    }

    /// The entry as a finite `Double`, or `nil`.
    ///
    /// `Double.init(_:)` alone is too generous for this: it accepts `inf`, `nan`
    /// and hexadecimal floats such as `0x1p3`, none of which is a SQL numeric
    /// literal, and it maps `1e400` to an infinity rather than refusing. So the
    /// spelling is checked against SQLite's own literal shape first and the
    /// result is required to be finite; everything else is text.
    private static func realValue(_ entry: String) -> Double? {
        guard isDecimalNumeral(entry), let value = Double(entry), value.isFinite else { return nil }
        return value
    }

    /// Whether the whole string is a decimal numeric literal:
    /// `[+-]? ( digits [ "." digits? ] | "." digits ) ( [eE] [+-]? digits )?`.
    ///
    /// `5.` and `.5` are both accepted, as SQLite accepts both; a string with no
    /// digit at all in the significand is not a numeral however many signs and
    /// points it carries.
    private static func isDecimalNumeral(_ entry: String) -> Bool {
        var characters = Substring(entry)
        if characters.first == "+" || characters.first == "-" { characters = characters.dropFirst() }

        let whole = takeDigits(&characters)
        var fraction = 0
        if characters.first == "." {
            characters = characters.dropFirst()
            fraction = takeDigits(&characters)
        }
        guard whole + fraction > 0 else { return false }

        if characters.first == "e" || characters.first == "E" {
            characters = characters.dropFirst()
            if characters.first == "+" || characters.first == "-" { characters = characters.dropFirst() }
            guard takeDigits(&characters) > 0 else { return false }
        }
        return characters.isEmpty
    }

    /// Consume the leading ASCII digits, answering how many there were.
    ///
    /// ASCII alone on purpose: `Double("٤٢")` is `nil`, and a rule that counted
    /// Arabic-Indic digits here would classify a string as a numeral that the
    /// parser then refuses, which is a disagreement between two halves of one
    /// answer.
    private static func takeDigits(_ characters: inout Substring) -> Int {
        var count = 0
        while let first = characters.first, first.isASCII, first.isNumber {
            characters = characters.dropFirst()
            count += 1
        }
        return count
    }

    /// The entry stored as `previousValue`'s storage class when it parses as one,
    /// and as text otherwise. The untyped-column rule, stated once.
    private static func valuePreservingClass(of previousValue: DatabaseValue, entry: String) -> DatabaseValue {
        switch previousValue {
        case .integer:
            return integerValue(entry).map(DatabaseValue.integer) ?? .text(entry)
        case .real:
            // A real cell keeps a real: an entry spelled as a whole number is
            // still a number this column was holding as one, so `43` over `4.5`
            // stores 43.0 rather than retyping the column to integer.
            return realValue(entry).map(DatabaseValue.real) ?? .text(entry)
        case .text, .blob, .null:
            return .text(entry)
        }
    }
}
