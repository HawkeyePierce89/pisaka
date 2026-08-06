import Foundation

/// What a git blob's bytes turned out to be.
///
/// The three cases are deliberately distinct and **none is expressible through
/// another** — which is the whole reason this type exists rather than a
/// `String?`. `.absent` is a fact about the *repository* (git has no object at
/// that path for that revision), decided by git's exit code; `.binary` and
/// `.text` are facts about the *bytes*, decided here. Collapsing the first into
/// the second (as `headContents(of:root:) -> String?` inevitably does) is what
/// makes a file that is binary in `HEAD` and text in the worktree look wholly
/// *added*, with per-line selection units against a falsely empty old side.
public enum BlobText: Equatable {
    /// The path does not exist at that revision (a new/untracked file).
    case absent
    /// The bytes are not text this editor can round-trip: a NUL sits in the
    /// probed head, or they are not valid UTF-8.
    case binary
    /// The decoded text.
    case text(String)

    /// The decoded text, or `nil` for `.absent`/`.binary`.
    public var text: String? {
        if case let .text(value) = self { return value }
        return nil
    }
}

/// Classifies raw git blob bytes as absent / binary / text, applying exactly the
/// rule `FileService.readTextIfNotBinary` applies to a worktree file — so the two
/// sides of a diff are judged by one standard and a file cannot be text on the
/// side that was read from disk while being "plausible garbage" on the side that
/// came through git.
///
/// **Why bytes and not a string.** `GitCLIService` decodes stdout *lossily*
/// (`String(decoding:as: UTF8.self)`), so invalid bytes become U+FFFD rather than
/// an error: a binary `HEAD` blob arriving as a `String` is indistinguishable
/// from ordinary text, and a strict decode would instead make it indistinguishable
/// from *absence*. Both readings misclassify, and both misclassify in the
/// dangerous direction — towards offering per-line selection over content that
/// cannot survive being reassembled line by line. So the accessor
/// (`GitServicing.headBlob(of:root:)`) hands back `Data?` with absence signalled
/// by git's exit code, and the decision is made here.
///
/// Foundation-only, pure and unit-tested in `GitBlobTextTests`.
public enum GitBlobText {
    /// Classify `data`, where `nil` means "git reported no object at this path"
    /// (i.e. `.absent`).
    ///
    /// The probe window is `FileService.binaryProbeBytes` (8000, git's own
    /// `buffer_is_binary` window): a NUL inside it means binary, a NUL past it
    /// does not — the same boundary a worktree read draws, deliberately shared
    /// rather than restated. Non-UTF-8 bytes are binary for the reason
    /// `readTextIfNotBinary` gives: an encoding the editor cannot round-trip must
    /// not be lossily decoded and then written back.
    public static func classify(_ data: Data?) -> BlobText {
        guard let data else { return .absent }
        guard !data.prefix(FileService.binaryProbeBytes).contains(0) else { return .binary }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }
}
