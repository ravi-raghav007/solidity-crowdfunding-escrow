# Stage 1 review record

Two independent reviewers, each with fresh context and no knowledge of how the code was written, examined stage 1. This file records what they found and how each finding was resolved. It is kept so the reasoning is visible later.

## Reviewer A: spec compliance

Verdict: the contract matched the spec line by line. No function, revert, event or status rule deviated. The findings were all about the tests and the spec.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The reentrancy tests still passed if `nonReentrant` was removed. Checks-effects-interactions already blocked the attack, so the tests never exercised the guard. Reviewer A proved this with a mutant contract. | Attacker contracts now record the exact error of each inner call. Tests assert it is `ReentrancyGuardReentrantCall`. Mutation test kills "remove nonReentrant". |
| 2 | Medium | The order of revert checks is part of the spec, but tests did not detect two checks being swapped. | 11 `test_Order_*` tests, each violating an earlier and a later check and asserting the earlier error. Mutation test kills both swap mutants. |
| 3 | Medium | Only three of the eight invariants were checked by the invariant suite. | The handler keeps its own record of every ETH movement. New invariants: exact ETH conservation, exact payout to the creator, `raised` frozen after the deadline, refunds bounded per backer. Also a scripted test proving the handler can reach payout and refund. |
| 4 | Low | Deadline boundary only covered by unit tests. | Accepted. Covered by `test_Pledge_ClosesExactlyAtDeadline` and `test_Attack_DeadlineBoundary`; Solidity tests are part of the gate. |
| 5 | Low | No test for ETH force-sent to the contract. | `test_ForcedEth_DoesNotChangePayoutOrRefunds`. |
| 6 | Low | Spec silent on view behaviour for unknown ids, public constants, and why `pledge` is unguarded. | Added to the spec. |
| 9 | Note | A loose `.rejected` assertion in the TypeScript test. | Replaced with a precise revert check. |

## Reviewer B: adversarial

Verdict: no way found to steal, lock or double-spend funds. 24 attack tests were written, all passing, including cross-campaign reentrancy, cross-function reentrancy, a return-data bomb, a gas-burning creator, a creator that rejects ETH, forced ETH, id 0 and huge ids, goal boundaries and a 256-run solvency fuzz.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Low | `uint64(deadline)` could silently truncate (unreachable with real timestamps). | Contract now reverts `InvalidDeadline` if the deadline would not fit. Test and spec updated. |
| 2 | Low | A creator can top up their own campaign in the last second to reach the goal with their own money. | Accepted and documented in the spec. Forbidding it cannot be enforced against a second wallet and would add code for no real protection. |
| 3 | Note | A creator can set a trivially small goal. | Documented as a trust-model limit; the interface must show the goal clearly. |
| 4 | Note | Forced ETH is stuck. | Already a documented limit. |
| 5 | Note | `pledge` must be guarded if it ever gets an external call. | Written into the spec as a rule for later stages. |
| 6 | Note | Return-bomb receiver is harmless. | No action. |

## Quality gates run

- Solidity unit, fuzz and attack tests, TypeScript end-to-end tests: all passing.
- Invariant tests: passing on the default profile, and on the `deep` profile (256 runs of 200 steps).
- Mutation test (`node scripts/mutation-test.mjs`): the contract is broken in 20 different ways, one at a time, and the suite must fail for every one.

## What this does not prove

Passing these checks makes serious mistakes much less likely. It does not make the contract bug-free, and nobody has independently audited it. It must not hold real funds until it has been audited.
