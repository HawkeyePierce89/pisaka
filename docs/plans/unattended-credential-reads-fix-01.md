# Fix plan 01 — answers revmux round 01-initial

## Overview

This plan answers the five defects confirmed by revmux round `01-initial` on task
`unattended-credential-reads`, plus the one its synthesis dropped as a duplicate
that is in fact a second, different rule. None of them blocks; three of them say
the contract this branch introduces is stated more strongly than it is enforced,
which is the class this repository treats as a defect in its own right.

Two decisions are already taken and are not to be reopened:

- The statement fetch **stays attended**. Its text comes to reality, not the
  other way round.
- Attended reads stay synchronous on the main actor. Taking them off it is a
  separate, larger ticket.

## Validation Commands

```sh
swift test
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' test
swiftlint --strict
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'platform=macOS' -configuration Release build
xcodebuild -project Pisaka.xcodeproj -scheme Pisaka -destination 'generic/platform=iOS' build
```

Derived data goes under `~/Library/Developer/Xcode/DerivedData/pisaka-<purpose>`,
never inside the repository.

## Implementation Steps

### Task 1: An unattended read that cannot silence the panel must refuse, not proceed

**File:** `Sources/Pisaka/Platform/LeetCodeKeychainStore.swift:156`

The defect as the review stated it: if `SecKeychainSetUserInteractionAllowed(false)`
returns an error, the code still runs `SecItemCopyMatching`. On a binary the login
keychain does not recognise, that query can raise the authorization panel during an
on-appear layout pass — the freeze this whole branch exists to prevent. The restore
call's result is discarded as well; if the restore fails, later attended reads may be
unable to ask until the process is restarted.

- [x] Bind the switch-off's status. On anything but success the unattended read
      returns that status **without** running the query. The caller already turns a
      non-success into `nil`, which is the answer the seam's contract requires, so no
      new state reaches Core.
- [x] Do not silently discard the restore's status either. It cannot be recovered
      from, but it must be visible in the file rather than dropped on the floor.
- [x] The comment explains why refusing is right: the guarantee this file makes is
      "an unattended read never waits on a person", and a query run with the switch
      in an unknown state is not that guarantee, it is the hope of it.
- [x] The test that would have caught this is structural, because nothing in the
      pipeline can drive the real Keychain: extend rule 5 (Task 2) so the switch-off's
      status must be bound and the query must be unreachable when it fails. Confirm by
      hand that the rule goes red when the binding is removed, then restore.
- [x] `swift test` must pass before the next task.

### Task 2: Rule 5 must hold "no exit leaves the process switched off", not "one defer exists"

**File:** `Tests/PisakaCoreTests/LeetCodeAccountSourceGatingTests.swift:383`

The defect: the doc comment and the failure message say the switch "is put back in a
`defer` so no exit leaves the process switched off". The assertion only requires the
pattern `defer { … SecKeychainSetUserInteractionAllowed( ` to match **at least once in
the file**. A second unattended path that switches interaction off without a defer —
or returns before restoring — keeps the rule green while leaving the process with
keychain interaction disabled, which is the exact defect the rule names. The
`#if os(macOS)` half of the same rule counts every spelling; the defer half does not.
This finding was dropped by the round's synthesis as a duplicate of rule 6's weakness;
it is a different rule and it is real.

- [x] Count the switch-offs — the calls whose argument is `false` — and require each
      to be matched by a restoring call in a `defer` within the same body. At minimum
      the two counts must agree, and a call inside a `defer` must not itself pass
      `false`.
- [x] Fold in Task 1's requirement: the status of each switch-off is bound, and the
      Keychain query is not reached on a failure.
- [x] Rewrite the rule's doc comment and its failure messages so they state exactly
      what is now asserted — a rule weaker than its own comment is what this task is
      about, and restating the old claim over a stronger assertion would repeat it.
- [x] Verify by hand that the rule goes red when a second
      `SecKeychainSetUserInteractionAllowed(false)` is added to the store with no
      defer, then remove the mutation and confirm green.
- [x] `swift test` must pass before the next task.

### Task 3: Rule 6 must pin the two named sites, not a token total

**File:** `Tests/PisakaCoreTests/LeetCodeAccountSourceGatingTests.swift:64` and `:323`

The defect: the rule's doc comment and `docs/architecture/core-leetcode.md:2671` both
say it pins the attended kind at two named sites — `requireCredentials()`'s fallback
read and `statement(forFileAt:in:)`'s fetch. The assertion is
`tokenCount("attended", in: code) == 2` over the whole model file plus
`unattended > 0`. Moving the attended kind from the statement fetch onto
`refreshUserStatus()`'s read, and making the statement fetch unattended, keeps the
count at two and the rule green — through the very regression it claims to guard.

- [ ] Assert the kind inside each named function's own brace-matched body, following
      the convention the gating suites already use for this shape, so the rule fails
      when a kind moves between functions even though the totals are unchanged.
- [ ] Keep a total as well, so a third attended site anywhere still has to be argued
      rather than slipping in beside a pinned one.
- [ ] Bring the doc comment, the failure messages and `core-leetcode.md`'s sentence
      into line with what is asserted.
- [ ] Verify by hand that the rule goes red under the swap described above, then
      restore and confirm green.
- [ ] `swift test` must pass before the next task.

### Task 4: L27 must name only the paths that actually recover

**Files:** `docs/architecture/core-leetcode.md:2658` and its known-limits bullet at
`:2726`; `Sources/PisakaCore/LeetCodeCredentials.swift:130`

The defect: all three say the attended fallback covers "opening a problem, the judge's
Run/Submit and context and the browser's lookup", and that a refusing keychain reads as
no session until the next explicit action, which then asks. After a refused unattended
read the account is signed out, so the judge refuses at its `guard isSignedIn` before
reaching `requireCredentials()`, and the browser's `currentCredentials()` returns `nil`
at the same guard. Run, Submit and browser Refresh therefore never make the attended
read. The branch's own tests already assert this.

- [ ] Say which two paths recover — opening a problem, and the statement fetch for a
      selected solution tab — and say plainly that the judge and the browser refuse on
      the signed-out state before they reach the read.
- [ ] Name the two tests that pin it, so the sentence and the assertions are readable
      against each other: the judge test asserting the reads after a Run are
      `[.unattended]`, and the browser test asserting a refused read shows the offer
      and asks nothing.
- [ ] No new test: the behaviour is already pinned by those two, and the defect is in
      the prose. The checkbox is to confirm, by reading them, that the corrected
      sentence says what they assert — not to add a third test for a claim already
      covered.
- [ ] `swift test` must pass before the next task.

### Task 5: The statement fetch's contract text must match when that read actually runs

**Files:** `Sources/PisakaCore/LeetCodeModel.swift:976`;
`Sources/PisakaCore/LeetCodeCredentials.swift:109`; `docs/architecture/core-leetcode.md:2661`
and the known-limits bullet

The defect, raised independently by all four agents: the comment, the attended case's
own doc and L27 all say this read follows "a deliberate solution-tab activation". Its
only trigger is a `.task(id:)` on the window root keyed on the selected file plus the
solutions folder, so it also runs when session restore selects a solution tab as the
window first appears, when the folder setting changes, and when closing another tab
moves the selection onto a solution file. On a machine whose login keychain does not
recognise the binary, the authorization panel can therefore appear at launch, before
the user has done anything. The read is not inside a layout pass and was interactive
before this branch too, so this is not the freeze being fixed — what is new is the
contract text asserting something that is not true of this site.

The decision is recorded: **the read stays attended and the text comes to reality.**

- [ ] Say that this read follows the *selection* of a solution tab, and that a
      selection can be restored at launch, moved by a folder change, or moved by
      closing another tab.
- [ ] Record as a known limit that on a machine whose keychain does not recognise the
      binary the panel can appear at launch through this path — outside any layout
      pass, and no worse than before this branch, which is why the read stays attended
      rather than being demoted.
- [ ] Make the three texts agree word for word on this point. They disagreeing again
      is the regression this task is about.
- [ ] If the trigger's composition can be pinned cheaply — that the statement key is
      the selected file and the folder and nothing else — add that assertion, so a
      future change to the trigger forces this sentence to be revisited. If it cannot
      be pinned without inventing a rule that holds less than it claims, say so in the
      progress log and add nothing: this task exists because a claim outran its
      enforcement.
- [ ] `swift test` must pass before the next task.

### Task 6: Run the gates

- [ ] `swift test` — full Core suite, report the exact count.
- [ ] The app-layer test bundle, report the exact count.
- [ ] `swiftlint --strict` from the repository root — must be clean.
- [ ] macOS Release build and the `generic/platform=iOS` build — both must succeed,
      with derived data outside the repository.
- [ ] Record in the progress log the by-hand red/green confirmations from Tasks 1, 2
      and 3, naming the mutation used for each.
