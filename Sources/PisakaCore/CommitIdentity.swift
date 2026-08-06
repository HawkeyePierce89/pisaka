import Foundation

/// Where one field of the commit author came from.
///
/// `.local` is the repository's own `.git/config`, `.global` is everything above
/// it that git resolved through (`~/.gitconfig`, the system config — they are one
/// answer as far as the dialog is concerned: "not this repository's"), and
/// `.unset` is a field git has no value for at all, which blocks the commit.
public enum IdentityFieldSource: String, Equatable {
    case local
    case global
    case unset
}

/// The author of the future commit, as the dialog shows it.
///
/// The feature exists for one failure it must make impossible: a work repository
/// silently committing under a personal *global* name because nothing on screen
/// ever said which config the identity came from. So the source is carried **per
/// field**, not per identity, and `signature` names a single source only when the
/// two fields genuinely share one — a name from `.git/config` next to an email
/// still coming from `~/.gitconfig` is the exact case a single "(local)" marker
/// would misreport, and it is an ordinary state to be in halfway through fixing a
/// repository's identity.
///
/// **The displayed value is the *effective* one** — what git will actually write
/// into the commit. The local read only decides the label; it never changes which
/// value is shown.
///
/// **Under Amend it is the committer, not the author**, and the view labels it so
/// (`CommitDialogView.authorLine`). `git commit --amend` without `--reset-author`
/// keeps the amended commit's author name, email and date and replaces only the
/// committer, so this identity is what git records in exactly one of the two roles
/// depending on a checkbox. The distinction is not carried in the type because
/// nothing here decides it: the value and its sources are the same either way, and
/// only the label the dialog puts in front of them changes.
///
/// **Editing writes the local config only.** Nothing in this feature touches the
/// global config: the dialog's editor runs `git config --local user.name/user.email`,
/// so fixing a repository's author can never change the identity of every other
/// repository on the machine. That is a deliberate limit, not an omission — the
/// global identity is a machine-wide setting and a commit dialog is the wrong
/// place to change one.
///
/// **Invariant: a value is empty exactly when its source is `.unset`.** The
/// initializer normalizes both directions (a blank value clears its source, an
/// `.unset` source clears its value), so no caller can construct an identity that
/// displays a name while reporting it missing — `isComplete` and `signature` then
/// key off the sources alone and cannot disagree with the text on screen.
///
/// Foundation-only, pure and unit-tested in `CommitIdentityTests`.
public struct CommitIdentity: Equatable {
    /// The effective author name, or `""` when unset.
    public let name: String
    /// The effective author email, or `""` when unset.
    public let email: String
    /// Which config level supplied `name`.
    public let nameSource: IdentityFieldSource
    /// Which config level supplied `email`.
    public let emailSource: IdentityFieldSource

    /// Builds an identity, normalizing the value/source invariant described on the
    /// type: values are trimmed, a blank value forces `.unset`, and an `.unset`
    /// source forces an empty value.
    public init(
        name: String,
        email: String,
        nameSource: IdentityFieldSource,
        emailSource: IdentityFieldSource
    ) {
        let (normalizedName, normalizedNameSource) = Self.normalize(name, nameSource)
        let (normalizedEmail, normalizedEmailSource) = Self.normalize(email, emailSource)
        self.name = normalizedName
        self.email = normalizedEmail
        self.nameSource = normalizedNameSource
        self.emailSource = normalizedEmailSource
    }

    private static func normalize(
        _ value: String,
        _ source: IdentityFieldSource
    ) -> (String, IdentityFieldSource) {
        guard source != .unset else { return ("", .unset) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ("", .unset) : (trimmed, source)
    }

    /// Whether git has both fields — the precondition for committing at all
    /// (`CommitGate` blocks otherwise, since git itself would refuse).
    public var isComplete: Bool {
        nameSource != .unset && emailSource != .unset
    }

    /// The author line shown in the dialog.
    ///
    /// `Name <email> (local)` when both fields come from the same config level,
    /// and a per-field spelling — `Name (local) <email> (global)` — the moment
    /// they differ, so the line can never claim one source for a mixed pair. An
    /// unset field is spelled `(name not set)` / `<email not set>` and carries no
    /// source marker, there being no source to name.
    public var signature: String {
        let nameText = nameSource == .unset ? "(name not set)" : name
        let emailText = emailSource == .unset ? "<email not set>" : "<\(email)>"
        if nameSource == emailSource, nameSource != .unset {
            return "\(nameText) \(emailText) (\(nameSource.rawValue))"
        }
        return "\(nameText)\(Self.marker(nameSource)) \(emailText)\(Self.marker(emailSource))"
    }

    private static func marker(_ source: IdentityFieldSource) -> String {
        source == .unset ? "" : " (\(source.rawValue))"
    }

    /// Decides each field's source from the pair "the value `git config --local
    /// --get` reported / the value `git config --get` resolved to".
    ///
    /// The effective value is the one shown and the one git will commit under; the
    /// local value only answers "did this repository supply it". A local key that
    /// is present but blank cannot be what git resolved to, so it does not claim
    /// `.local`; an effective value that is absent or blank is `.unset` regardless
    /// of what either level holds.
    public static func resolve(
        localName: String?,
        localEmail: String?,
        effectiveName: String?,
        effectiveEmail: String?
    ) -> CommitIdentity {
        let (name, nameSource) = resolveField(local: localName, effective: effectiveName)
        let (email, emailSource) = resolveField(local: localEmail, effective: effectiveEmail)
        return CommitIdentity(
            name: name,
            email: email,
            nameSource: nameSource,
            emailSource: emailSource
        )
    }

    private static func resolveField(
        local: String?,
        effective: String?
    ) -> (String, IdentityFieldSource) {
        let trimmedEffective = (effective ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEffective.isEmpty else { return ("", .unset) }
        let trimmedLocal = (local ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmedEffective, trimmedLocal.isEmpty ? .global : .local)
    }
}
