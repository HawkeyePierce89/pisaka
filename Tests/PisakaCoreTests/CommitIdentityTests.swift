import XCTest
@testable import PisakaCore

final class CommitIdentityTests: XCTestCase {

    // MARK: - Signature: a single source only when both fields really share one

    func testBothFieldsLocalNameTheSourceOnce() {
        let identity = CommitIdentity.resolve(
            localName: "Anton Karmanov",
            localEmail: "anton@work.example",
            effectiveName: "Anton Karmanov",
            effectiveEmail: "anton@work.example"
        )
        XCTAssertEqual(identity.nameSource, .local)
        XCTAssertEqual(identity.emailSource, .local)
        XCTAssertEqual(identity.signature, "Anton Karmanov <anton@work.example> (local)")
    }

    func testBothFieldsGlobalNameTheSourceOnce() {
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: nil,
            effectiveName: "Anton Karmanov",
            effectiveEmail: "anton@personal.example"
        )
        XCTAssertEqual(identity.nameSource, .global)
        XCTAssertEqual(identity.emailSource, .global)
        XCTAssertEqual(identity.signature, "Anton Karmanov <anton@personal.example> (global)")
    }

    func testMixedSourcesNameEachFieldSeparately() {
        // The whole point of the feature: a work repository must not be able to
        // show one reassuring "(local)" while the email is still the personal
        // global one. Each field carries its own source and no single claim is
        // made about the pair.
        let identity = CommitIdentity.resolve(
            localName: "Anton Karmanov",
            localEmail: nil,
            effectiveName: "Anton Karmanov",
            effectiveEmail: "anton@personal.example"
        )
        XCTAssertEqual(identity.nameSource, .local)
        XCTAssertEqual(identity.emailSource, .global)
        XCTAssertEqual(
            identity.signature,
            "Anton Karmanov (local) <anton@personal.example> (global)"
        )
    }

    func testMixedSourcesTheOtherWayAround() {
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: "anton@work.example",
            effectiveName: "Anton Karmanov",
            effectiveEmail: "anton@work.example"
        )
        XCTAssertEqual(identity.nameSource, .global)
        XCTAssertEqual(identity.emailSource, .local)
        XCTAssertEqual(
            identity.signature,
            "Anton Karmanov (global) <anton@work.example> (local)"
        )
    }

    func testMixedSignatureNeverEndsInASingleSourceClaim() {
        // A structural restatement of the rule above, so a future reformatting of
        // the signature cannot quietly collapse a mixed pair into one marker.
        let mixed = CommitIdentity.resolve(
            localName: "Anton Karmanov",
            localEmail: nil,
            effectiveName: "Anton Karmanov",
            effectiveEmail: "anton@personal.example"
        )
        XCTAssertTrue(mixed.signature.contains("(local)"))
        XCTAssertTrue(mixed.signature.contains("(global)"))
    }

    // MARK: - Unset fields

    func testAbsentNameIsUnsetAndIncomplete() {
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: nil,
            effectiveName: nil,
            effectiveEmail: "anton@personal.example"
        )
        XCTAssertEqual(identity.nameSource, .unset)
        XCTAssertEqual(identity.name, "")
        XCTAssertEqual(identity.emailSource, .global)
        XCTAssertFalse(identity.isComplete)
        XCTAssertEqual(identity.signature, "(name not set) <anton@personal.example> (global)")
    }

    func testEmptyEmailIsUnsetAndIncomplete() {
        // `git config --get user.email` on an explicitly emptied key returns an
        // empty string rather than failing, so "" must mean the same as absent.
        let identity = CommitIdentity.resolve(
            localName: "Anton Karmanov",
            localEmail: "",
            effectiveName: "Anton Karmanov",
            effectiveEmail: ""
        )
        XCTAssertEqual(identity.emailSource, .unset)
        XCTAssertEqual(identity.email, "")
        XCTAssertFalse(identity.isComplete)
        XCTAssertEqual(identity.signature, "Anton Karmanov (local) <email not set>")
    }

    func testWhitespaceOnlyValueIsUnset() {
        let identity = CommitIdentity.resolve(
            localName: "   ",
            localEmail: nil,
            effectiveName: "   ",
            effectiveEmail: "anton@personal.example"
        )
        XCTAssertEqual(identity.nameSource, .unset)
        XCTAssertEqual(identity.name, "")
        XCTAssertFalse(identity.isComplete)
    }

    func testBothFieldsUnset() {
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: nil,
            effectiveName: nil,
            effectiveEmail: nil
        )
        XCTAssertEqual(identity.nameSource, .unset)
        XCTAssertEqual(identity.emailSource, .unset)
        XCTAssertFalse(identity.isComplete)
        XCTAssertEqual(identity.signature, "(name not set) <email not set>")
        // Nothing is claimed about a source that does not exist.
        XCTAssertFalse(identity.signature.contains("(local)"))
        XCTAssertFalse(identity.signature.contains("(global)"))
    }

    func testCompleteWhenBothFieldsResolve() {
        let identity = CommitIdentity.resolve(
            localName: "Anton Karmanov",
            localEmail: "anton@work.example",
            effectiveName: "Anton Karmanov",
            effectiveEmail: "anton@work.example"
        )
        XCTAssertTrue(identity.isComplete)
    }

    // MARK: - Source resolution details

    func testValuesAreTrimmed() {
        let identity = CommitIdentity.resolve(
            localName: "  Anton Karmanov\n",
            localEmail: "  anton@work.example\n",
            effectiveName: "  Anton Karmanov\n",
            effectiveEmail: "  anton@work.example\n"
        )
        XCTAssertEqual(identity.name, "Anton Karmanov")
        XCTAssertEqual(identity.email, "anton@work.example")
    }

    func testTheEffectiveValueIsTheOneShown() {
        // The effective value is what git will actually put in the commit, so it
        // is what the dialog must display — the local read only decides the
        // *source* label.
        let identity = CommitIdentity.resolve(
            localName: nil,
            localEmail: nil,
            effectiveName: "Global Name",
            effectiveEmail: "global@example"
        )
        XCTAssertEqual(identity.name, "Global Name")
        XCTAssertEqual(identity.email, "global@example")
    }

    func testWhitespaceOnlyLocalValueDoesNotClaimLocal() {
        // A local key present but blank cannot be what git resolved to, so the
        // effective value must be attributed to the global config.
        let identity = CommitIdentity.resolve(
            localName: "  ",
            localEmail: nil,
            effectiveName: "Global Name",
            effectiveEmail: "global@example"
        )
        XCTAssertEqual(identity.nameSource, .global)
    }

    // MARK: - The value/source invariant

    func testUnsetSourceForcesAnEmptyValue() {
        // The type keeps "value empty ⟺ source .unset" structural, so no caller
        // can build a value that displays a name while reporting it unset.
        let identity = CommitIdentity(
            name: "Anton Karmanov",
            email: "anton@work.example",
            nameSource: .unset,
            emailSource: .local
        )
        XCTAssertEqual(identity.name, "")
        XCTAssertFalse(identity.isComplete)
    }

    func testEmptyValueForcesAnUnsetSource() {
        let identity = CommitIdentity(
            name: "",
            email: "anton@work.example",
            nameSource: .local,
            emailSource: .local
        )
        XCTAssertEqual(identity.nameSource, .unset)
        XCTAssertFalse(identity.isComplete)
    }
}
