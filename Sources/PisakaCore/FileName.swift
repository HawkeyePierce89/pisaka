import Foundation

/// Whether `name` is usable as a single file or directory name.
///
/// Pure, testable validation for the project-tree *rename* dialog. (The
/// path-accepting create dialogs do not go through here — they share only the
/// per-component rule, `componentIssue(_:isReserved:)` below, via
/// `parseRelativeEntryPath(_:)`; this predicate additionally rejects any `/`,
/// which there is a separator rather than an error.)
/// Rejects an empty or whitespace-only name, the directory-navigation names
/// `.` and `..`, and any name containing a path separator (`/`), a NUL (`\0`),
/// or a line break *that survives trimming* — i.e. it must name *one* new entry,
/// not a path or a reference to an existing directory. Leading/trailing
/// whitespace is allowed within an otherwise non-blank name and is trimmed
/// before the scan, so `"a\n"` is accepted while `"a\nb"` is not; callers trim as
/// they see fit. Dotfiles (e.g. `.gitignore`) are accepted.
///
/// This is the boolean-shaped facade over `validateSingleEntryName(_:)`: both go
/// through the same shared rule, so the predicate and the reasoned validator can
/// never drift — except on *reserved* names, which this predicate deliberately
/// does not judge (the rename call site checks `FileService.isExcludedEntryName`
/// separately, and the create dialogs use `validateRelativeEntryPath(_:)`'s
/// case-insensitive policy instead). The tests assert exactly that on a matrix.
///
/// The separator/NUL scan runs over *unicode scalars*, not `Character`s: a
/// combining mark following a `/` (e.g. `a/` + U+0338) fuses into a single
/// grapheme cluster that compares unequal to `"/"`, so a `Character`-level scan
/// would pass a name whose on-disk path really does contain a separator — the
/// entry would then land in a directory the user never named.
public func isValidFileName(_ name: String) -> Bool {
    singleEntryNameIssue(name, isReserved: { _ in false }) == nil
}

/// Why a user-entered entry name or relative path cannot be used, together with
/// the human-readable reason the dialog shows under the input field.
///
/// The reason texts live here rather than in the view layer for the same reason
/// `GitError.errorDescription` and `FileServiceError`'s `LocalizedError` texts
/// do: the decision and its explanation are one rule, unit-tested together, and
/// the AppKit prompt stays a thin display of whatever the validator returns.
public enum EntryPathIssue: Equatable {
    /// The whole input is empty or whitespace-only.
    case emptyInput
    /// A component is empty after trimming — `a//b`, a leading `/`, a second
    /// trailing slash (`a//`), or a whitespace-only component (`a/ /b`).
    case emptyComponent
    /// A component is a directory-navigation name (`.` or `..`), carried so the
    /// message can name the one the user typed.
    case navigationComponent(String)
    /// A `/` appeared in a context that takes a single name (rename).
    case separatorInName
    /// A line break inside a component. Only reachable by paste — the prompt's
    /// Enter confirms instead of inserting a newline.
    case lineBreak
    /// A NUL scalar inside a component.
    case nulCharacter
    /// A reserved service name (`.git` / `.DS_Store`), carried so the message
    /// can name the offending component as the user spelled it.
    case reservedComponent(String)

    /// The reason shown to the user, in the style of the existing alert texts.
    public var message: String {
        switch self {
        case .emptyInput:
            return "Enter a name."
        case .emptyComponent:
            return "Each part of the path must be non-empty."
        case .navigationComponent(let name):
            return "\"\(name)\" refers to an existing folder, not a new entry."
        case .separatorInName:
            return "A name must not contain a slash — renaming takes a single name, not a path."
        case .lineBreak:
            return "A name must not contain a line break."
        case .nulCharacter:
            return "A name must not contain a NUL character."
        case .reservedComponent(let name):
            return "\"\(name)\" is a reserved name and is never shown in the project tree."
        }
    }
}

/// The one component-level rule shared by `parseRelativeEntryPath(_:)`,
/// `validateRelativeEntryPath(_:)`, `validateSingleEntryName(_:)`, and
/// `isValidFileName(_:)`, so the parser and the reasoned validators can never
/// drift into two implementations of the same rule.
///
/// `component` must already be trimmed. `isReserved` is the per-context
/// reserved-name policy (case-insensitive for create paths, exact-match for
/// rename, none for the plain-name predicate), matching the corresponding
/// post-OK guard exactly so a dialog can never block a name the guard accepts.
private func componentIssue(_ component: String, isReserved: (String) -> Bool) -> EntryPathIssue? {
    if component.isEmpty { return .emptyComponent }
    if component == "." || component == ".." { return .navigationComponent(component) }
    if component.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
        return .lineBreak
    }
    if component.unicodeScalars.contains("\0") { return .nulCharacter }
    if isReserved(component) { return .reservedComponent(component) }
    return nil
}

/// The one splitter shared by the path parser and the path validator: trim the
/// whole input, tolerate exactly one trailing `/`, split on `/` *without*
/// omitting empty subsequences, and trim every component. Returns `nil` for an
/// empty or whitespace-only input (the `.emptyInput` case).
///
/// The split runs over *unicode scalars* rather than `Character`s: a `/`
/// followed by a combining mark fuses into one grapheme cluster, so a
/// `Character`-level split would hand back a "single component" whose on-disk
/// path still contains a real separator (see `isValidFileName(_:)`).
private func relativePathComponents(_ path: String) -> [String]? {
    var scalars = path.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
    if scalars.isEmpty { return nil }
    if scalars.last == "/" { scalars.removeLast() }

    return scalars
        .split(separator: "/", omittingEmptySubsequences: false)
        .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Why the user-entered *relative* path cannot be created, or `nil` when it is
/// valid — the reasoned form of `parseRelativeEntryPath(_:)`, which the New File
/// / New Folder dialogs run on every keystroke to show a reason and gate OK.
///
/// Reports, in order of the first offending component: `.emptyInput` for an
/// empty/whitespace-only input; `.emptyComponent`, `.navigationComponent`,
/// `.lineBreak`, `.nulCharacter`; and `.reservedComponent` per
/// `FileService.isReservedCreateName(_:)` — `.git` / `.DS_Store` in *any*
/// casing, so neither `x/.git/y` nor `x/.GIT/y` can write inside the hidden
/// repository directory on a case-insensitive volume.
public func validateRelativeEntryPath(_ path: String) -> EntryPathIssue? {
    guard let components = relativePathComponents(path) else { return .emptyInput }
    for component in components {
        if let issue = componentIssue(component, isReserved: FileService.isReservedCreateName) {
            return issue
        }
    }
    return nil
}

/// The one single-name rule shared by `validateSingleEntryName(_:)` and
/// `isValidFileName(_:)`, parameterized by the caller's reserved-name policy.
///
/// Unlike the path grammar, a `/` is never a separator here — the input must be
/// *one* name — so it is reported as `.separatorInName` before the shared
/// `componentIssue(_:isReserved:)` judges the rest. The whole input is trimmed
/// first, so surrounding whitespace (and a surrounding line break) is allowed in
/// an otherwise valid name; the scan runs over unicode scalars for the
/// hidden-separator reason documented on `isValidFileName(_:)`.
private func singleEntryNameIssue(_ name: String,
                                  isReserved: (String) -> Bool) -> EntryPathIssue? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .emptyInput }
    if trimmed.unicodeScalars.contains("/") { return .separatorInName }
    return componentIssue(trimmed, isReserved: isReserved)
}

/// Why the user-entered *single* entry name cannot be used, or `nil` when it is
/// valid — the reasoned form of `isValidFileName(_:)` plus the reserved-name
/// rule, which the project-tree Rename dialog runs on every keystroke to show a
/// reason and gate OK.
///
/// Reports `.emptyInput` for an empty/whitespace-only input; `.separatorInName`
/// for *any* `/` (rename takes a single name, not a path — a move is a separate
/// feature, and an entry created through a path there would land on disk yet
/// never appear in the tree); then `.navigationComponent`, `.lineBreak`,
/// `.nulCharacter`; and `.reservedComponent` per
/// `FileService.isExcludedEntryName(_:)`.
///
/// The reserved check is deliberately the **exact-match** one, not the
/// case-insensitive `isReservedCreateName(_:)` the create paths use: it mirrors
/// the rename call site's own post-OK guard, so the dialog can never block a
/// name that guard would accept (a user's own `.Git` folder is an ordinary,
/// visible entry) or accept one it would reject.
public func validateSingleEntryName(_ name: String) -> EntryPathIssue? {
    singleEntryNameIssue(name, isReserved: FileService.isExcludedEntryName)
}

/// Split a user-entered *relative* path into its entry-name components, or
/// `nil` when it does not name a creatable entry.
///
/// Pure, testable validation for the project-tree's New File / New Folder
/// dialogs, which accept a path of any depth (`centrifugo/config.json`) rather
/// than a single name: the caller creates the missing intermediate folders and
/// then the final entry.
///
/// The whole input is trimmed first, then exactly *one* trailing `/` is
/// tolerated (so `a/b/` — the natural way to spell a folder — parses as
/// `["a", "b"]`; because the input is trimmed first, a padded `a/   ` is the
/// same case).
///
/// This is the boolean-shaped facade over `validateRelativeEntryPath(_:)`: both
/// go through the same splitter and the same component rule, so a path parses
/// exactly when the validator reports no issue (asserted on a matrix in the
/// tests). A component containing a *line break* is rejected — pasting `a\nb`
/// used to create a file with a newline in its name.
public func parseRelativeEntryPath(_ path: String) -> [String]? {
    guard let components = relativePathComponents(path) else { return nil }
    for component in components {
        if componentIssue(component, isReserved: FileService.isReservedCreateName) != nil {
            return nil
        }
    }
    return components
}
