import Foundation

/// One `key = value` pair exactly as one section spelled it, in document order.
///
/// The key is trimmed and lowercased; the value is trimmed, and lowercased only
/// for the known property set (an unknown property's value may be a path, a
/// command or anything else, so it is carried verbatim).
public struct EditorConfigPair: Equatable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One `[glob]` section: the compiled section name plus its pairs in the order
/// the file wrote them.
///
/// Pairs stay an ordered array rather than a dictionary because the merge is
/// defined as "apply in document order" — which is also what makes a duplicate
/// key inside one section last-wins, with no separate rule for it.
public struct EditorConfigSection: Equatable {
    public let glob: EditorConfigGlob
    public let pairs: [EditorConfigPair]

    public init(glob: EditorConfigGlob, pairs: [EditorConfigPair]) {
        self.glob = glob
        self.pairs = pairs
    }

    /// The effective value of `key` in this section — the last one written.
    public func value(for key: String) -> String? {
        pairs.last { $0.key == key.lowercased() }?.value
    }
}

/// One `.editorconfig` file's text, parsed into its preamble flag and its
/// ordered sections.
///
/// Parsing never fails: a malformed line is skipped and the rest of the file is
/// still read, which is what keeps one typo in a shared config from silently
/// dropping every rule below it.
///
/// Three rules are worth stating because implementations differ:
///
/// - **Comments are line comments only.** A `#` or `;` starts a comment only as
///   the first non-whitespace character of a line; anywhere else it is ordinary
///   text belonging to the value, per the spec's explicit prohibition of inline
///   comments. So `foo = a ;)` has the value `a ;)`.
/// - **`root` is a preamble declaration.** It is honored only before the first
///   section and compared case-insensitively; a `root = true` written under a
///   section is just one more property of that section.
/// - **The spec's required acceptance floors are taken as the cap**: a key
///   longer than 1024 characters or a value longer than 4096 is ignored, as is
///   a section name longer than 1024 (`EditorConfigGlob`'s own limit).
public struct EditorConfigFile: Equatable {
    /// The longest key that is honored (the spec's acceptance floor).
    public static let maximumKeyLength = 1024
    /// The longest value that is honored (the spec's acceptance floor).
    public static let maximumValueLength = 4096

    /// `root = true` was declared in the preamble: the hierarchy walk stops
    /// here.
    public let isRoot: Bool
    /// Every section, in document order.
    public let sections: [EditorConfigSection]

    public init(text: String) {
        var isRoot = false
        var sections: [EditorConfigSection] = []
        var currentGlob: EditorConfigGlob?
        var currentPairs: [EditorConfigPair] = []

        func closeCurrentSection() {
            guard let glob = currentGlob else { return }
            sections.append(EditorConfigSection(glob: glob, pairs: currentPairs))
            currentPairs = []
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Line comments only — the check is on the first character of the
            // trimmed line and nowhere else.
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") {
                guard let name = EditorConfigFile.sectionName(line) else { continue }
                closeCurrentSection()
                currentGlob = EditorConfigGlob(pattern: name)
                continue
            }

            guard let pair = EditorConfigFile.pair(line, lowercasingValue: currentGlob != nil) else { continue }
            if currentGlob == nil {
                // The preamble carries exactly one meaningful declaration.
                if pair.key == "root" { isRoot = pair.value.lowercased() == "true" }
                continue
            }
            currentPairs.append(pair)
        }
        closeCurrentSection()

        self.isRoot = isRoot
        self.sections = sections
    }

    /// Every section matching `relativePath`, in document order.
    public func sections(matching relativePath: String) -> [EditorConfigSection] {
        var budget = EditorConfigGlob.maximumMatchSteps
        return sections(matching: relativePath, budget: &budget)
    }

    /// The same list against a budget the caller owns, so the whole outward walk
    /// — every section of every file it reads — shares one ceiling instead of
    /// one per section (see `EditorConfigGlob.maximumMatchSteps`).
    func sections(matching relativePath: String, budget: inout Int) -> [EditorConfigSection] {
        var matching: [EditorConfigSection] = []
        for section in sections where section.glob.matches(relativePath: relativePath, budget: &budget) {
            matching.append(section)
        }
        return matching
    }

    // MARK: - Lines

    /// The text between the leading `[` and the **last** `]` on the line, or
    /// `nil` when the header never closes.
    private static func sectionName(_ line: String) -> String? {
        guard let close = line.lastIndex(of: "]"), close > line.startIndex else { return nil }
        return String(line[line.index(after: line.startIndex)..<close])
    }

    /// A `key = value` line split at its **first** `=`, so a value may hold as
    /// many more as it likes. `nil` when the line is not a pair at all, or when
    /// either half exceeds its length cap.
    private static func pair(_ line: String, lowercasingValue: Bool) -> EditorConfigPair? {
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.count <= maximumKeyLength, value.count <= maximumValueLength else { return nil }
        // Known properties have a closed value vocabulary and are compared
        // case-insensitively; an unknown one may carry anything.
        if lowercasingValue, EditorConfigProperties.knownKeys.contains(key) { value = value.lowercased() }
        return EditorConfigPair(key: key, value: value)
    }
}

/// The merged property map for one file: every property that applied, whether
/// or not this app knows what it means.
///
/// Unknown properties are carried, never dropped — a later part of the feature,
/// or a plugin-shaped consumer, reads them through `subscript(key:)`; the typed
/// accessors below cover only the three properties the editor acts on today.
public struct EditorConfigProperties: Equatable {
    /// The properties whose *values* are case-insensitive, per the spec. Used
    /// by the parser to decide what may be lowercased on the way in.
    public static let knownKeys: Set<String> = [
        "indent_style",
        "indent_size",
        "tab_width",
        "end_of_line",
        "charset",
        "trim_trailing_whitespace",
        "insert_final_newline",
        "max_line_length",
        "root",
    ]

    /// The whole merged map, keys already lowercased.
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    public subscript(key: String) -> String? {
        values[key.lowercased()]
    }

    /// Applies one pair, which for the value `unset` (case-insensitive) means
    /// *removing* the property rather than setting it — the spec's way of
    /// letting a closer file undo an inherited rule.
    public mutating func apply(_ pair: EditorConfigPair) {
        if pair.value.lowercased() == "unset" {
            values.removeValue(forKey: pair.key)
        } else {
            values[pair.key] = pair.value
        }
    }

    // MARK: - The three consumed properties

    /// `indent_style`: tabs or spaces.
    public enum IndentStyle: String, Equatable {
        case tab
        case space
    }

    /// `indent_size`: a width, or the word `tab` deferring to `tab_width`.
    public enum IndentSize: Equatable {
        case tab
        case width(Int)
    }

    /// `.tab`/`.space`, or `nil` when absent or unrecognized.
    public var indentStyle: IndentStyle? {
        values["indent_style"].flatMap(IndentStyle.init(rawValue:))
    }

    /// `.tab` for the literal word, `.width` for a positive integer, `nil`
    /// otherwise — `0`, a negative number and anything non-numeric are all
    /// treated as absent rather than as an error.
    public var indentSize: IndentSize? {
        guard let raw = values["indent_size"] else { return nil }
        if raw == "tab" { return .tab }
        return EditorConfigProperties.positiveInteger(raw).map(IndentSize.width)
    }

    /// The explicit `tab_width`, falling back to a numeric `indent_size` — the
    /// default the spec states for the property.
    public var tabWidth: Int? {
        if let explicit = values["tab_width"].flatMap(EditorConfigProperties.positiveInteger) { return explicit }
        if case .width(let width) = indentSize { return width }
        return nil
    }

    /// How wide one indentation level is, in columns, following the spec's
    /// coupling in both directions: a numeric `indent_size` is the answer;
    /// `indent_size = tab` defers to the *explicit* `tab_width`; and with no
    /// `indent_size` at all a stated `tab_width` still describes the width.
    public var indentWidth: Int? {
        switch indentSize {
        case .width(let width):
            return width
        case .tab:
            return values["tab_width"].flatMap(EditorConfigProperties.positiveInteger)
        case nil:
            return values["tab_width"].flatMap(EditorConfigProperties.positiveInteger)
        }
    }

    /// A strictly positive decimal integer, or `nil`.
    private static func positiveInteger(_ raw: String) -> Int? {
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(raw), value > 0 else {
            return nil
        }
        return value
    }
}
