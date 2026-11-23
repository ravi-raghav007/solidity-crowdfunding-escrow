# Stage 2 review record

Two independent reviewers (fresh context, no knowledge of how the code was written) examined stage 2: a spec-compliance reviewer and an adversarial reviewer who played a malicious owner, creator, backer and fee recipient. This file records every finding and its resolution.

## Reviewer A: spec compliance

Verdict: the contract matched both specs line by line. No code deviation was found. All findings were test gaps, spec wording, or came from the other reviewer's tests.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The low-level ETH send copies the receiver's return data, so a recipient returning a huge buffer makes `claimFees` cost millions of gas. | Fixed in the contract: a private `_sendEth` uses assembly with a zero-size return buffer, used by `withdraw`, `refund` and `claimFees`. The attack tests now assert the fixed behaviour. See Reviewer B finding 1. |
| 2 | Medium | The `CreationPausedUpdated` event was not tested. Removing the emit or emitting the wrong value passed every test. | `test_Pause_EmitsEventWithTheNewValue` checks both values. |
| 3 | Low | Event checks used only the indexed topic. | Accepted. The affected events have one indexed argument and no data. |
| 4 | Low | Constructor check order untested. | `test_Order_Constructor_OwnerBeforeRecipientBeforeFee`. |
| 5 | Low | Owner-check versus value-check order untested. | `test_Order_Admin_NotOwnerBeforeBadValue`. |
| 6 | Low | Ownable2Step coverage thin (non-owner transfer, pending owner rights, cancelling, renounce while pending). | Four new ownership tests. The spec now says the owner can cancel a pending transfer. |
| 7 | Low | Reentrancy with a non-zero fee was only tested from the recipient side. | `test_Reentrancy_CreatorCannotClaimFeesDuringItsOwnPayout`. |
| 8 | Low | The TypeScript end-to-end test only ran at fee 0. | New `test/CrowdfundFees.ts` with six end-to-end tests at 8%. |
| 9 | Low | The invariant fuzzer might pass vacuously if it never reached stage 2 paths. | Scripted reachability tests, plus the mutation test run in invariants-only mode, which shows which breakages the invariants themselves detect. |
| 10 | Note | The test "GoalNotReached before AlreadyPaid" cannot discriminate, because the two conditions can never hold together. | Accepted as an equivalent mutant. The test stays as documentation. |
| 11 | Note | The order of effects before the send cannot be observed from outside, because the shared reentrancy guard blocks re-entry. | Accepted as a code-quality rule. |
| 12 | Note | `Math.mulDiv` versus plain multiplication cannot be told apart by any realistic test. | Accepted. mulDiv is kept as defence in depth. |
| 13 | Note | Spec wording: stage 1 I3, I7 and "no owner" not amended; I13 overstated; `getCampaign` field order unspecified; lost-owner-key behaviour unstated. | New "Amendments to stage 1" section, reworded I13, field order pinned by `test_Abi_GetCampaignFieldOrder`, lost-key behaviour documented. |

## Reviewer B: adversarial

Verdict: no way found to steal, lock or double-spend campaign funds. 32 attack tests were written. Attacks that did not work include: raising the fee on an existing campaign, exceeding the 10% cap (including raw calldata above uint16), changing the fee after accrual, locking funds with the pause, renouncing ownership through any caller, a reentrant, gas-burning or rejecting fee recipient, double claims, rounding and dust at every size from 1 wei, `mulDiv` overflow, and a 40-step random solvency fuzz.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Low | Return-bomb recipient makes `claimFees` cost millions of gas. The stage 1 review had called a return-bomb "harmless", which is true for creators and backers but not for the permissionless `claimFees`. | Fixed as above. Mutation test includes "ETH send copies the return data again". |
| 2 | Low | The owner can raise the fee right before a creator's `createCampaign`, locking the campaign at a higher fee than the creator saw. | `createCampaign` now takes `maxFeeBps` and reverts with `FeeAboveMax`. Tests, spec and fuzzer updated. |
| 3 | Note | OpenZeppelin quirk: after a transfer to `address(0)`, a call from `address(0)` could accept it. | Unreachable on a real chain (nobody holds that key). Documented. |
| 4 | Note | A creator contract that cannot receive ETH locks its own campaign. | Documented as a known limit. A payout address may come later. |
| 5 | Note | The owner can redirect accrued fees by changing the recipient before a claim. | Already documented. I13 reworded to say so. |

## What changed in the contract after review

- `_sendEth` helper (no return-data copy), used for every payout.
- `createCampaign(goal, deadline, maxFeeBps)` and the `FeeAboveMax` error.

## Quality gates run

- 166 Solidity tests (unit, fuzz, attack, invariant) and 11 TypeScript end-to-end tests pass.
- Invariants pass on the default and `deep` profiles.
- Mutation test (`node scripts/mutation-test.mjs`): the contract is broken in many different ways, one at a time, and the suite must fail for every one. Result: 45 of 45 mutants killed.

## Checking the fuzzer itself

A random-action fuzzer can pass without testing anything if it rarely reaches the interesting paths. Reviewer A warned about this (finding 9), so the mutation test was run in invariants-only mode (`node scripts/mutation-test.mjs --invariants-only`), which shows which deliberate breakages the invariants detect without any help from the unit tests.

- First run: only 15 of 45 breakages were detected. Two of the survivors, "withdraw does not accrue the fee" and "creator receives the full amount, no fee deducted", showed the fuzzer almost never reached a successful payout with a fee.
- Fix: new guided actions (fund a campaign exactly to its goal, jump to a campaign deadline) and new forbidden-action probes (non-owner admin calls, non-creator withdraws, zero-value pledges, zero goals) with a new invariant that none of them ever succeeds. The default fuzz size was raised to 64 runs of 100 steps.
- Second run: 25 of 45 detected, including both payout-with-fee breakages. One more was cut off by the time limit.
- The remaining survivors are things a random fuzzer cannot see by design: a missing reentrancy guard (needs a malicious contract), the order of error checks, constructor validation, exact boundary values, id numbering, ignored send failures, and the return-data copy. The unit tests detect all of them: the full mutation run kills 45 of 45.

## What this does not prove

The checks make serious mistakes much less likely. They do not make the contract bug-free, and nobody has independently audited it. It must not hold real funds until it has been audited.
