# Stage 3 review record

Two independent reviewers (fresh context, no knowledge of how the code was written) examined stage 3: a spec-compliance reviewer, and an adversarial reviewer who played a malicious token issuer, owner, creator, backer and fee recipient, writing hostile tokens of their own. This file records every finding and its resolution.

## Reviewer A: spec compliance

Verdict: the contract matched all three specs with no code deviation, and the ETH behaviour of stages 1 and 2 was unchanged. The findings were test gaps, one real edge case, and spec wording.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Medium | The exact-received check could be weakened from "exactly" to "at least" without any test failing, because every test token under-delivered and none over-delivered. The reviewer proved it with a mutated copy. | New `MisdeliveringToken` helper. `test_OverDelivery_IsRejectedToo` and a fuzz test over random positive and negative deltas. The mutation test includes the weakened check. |
| 2 | Medium | No test used two different tokens in one contract, so a bug mixing the fee counters or balances of two tokens would pass everything. | Two new unit tests with two tokens, and the invariant suite now has a second token with solvency, conservation and fee accounting checked per token. |
| 3 | Low | A fee recipient equal to the contract itself silently strands token fees (the claim succeeds and the tokens stay in the contract). With ETH the same setup fails loudly. | Fixed in the contract: `setFeeRecipient` and the constructor reject the contract itself (`InvalidRecipient`). See also Reviewer B finding 1. |
| 4 | Low | The fuzzer did not check that creation is impossible while paused or with a disallowed token. | The handler flags any campaign created while paused or with a disallowed token, and a scripted test proves the check can trigger. |
| 5 | Low | The older ABI-order test decoded only seven fields. | A newer test pins the eighth field (`token`), and the spec now states both. |
| 6 | Low | No end-to-end TypeScript test of the token functions. | `test/CrowdfundTokens.ts` (seven end-to-end tests). |
| 7 | Note | The spec said the ETH functions were "unchanged" although `pledge`, the `CampaignCreated` event and `getCampaign` changed. | New "Amendments to stages 1 and 2" section. |
| 8 | Note | `setTokenAllowed` accepted any non-zero address. | Fixed in the contract and documented (see Reviewer B finding 5). |
| 9 | Note | ETH `pledge` is not `nonReentrant`. | Kept on purpose and now explained in a code comment and in the spec. |

## Reviewer B: adversarial

Verdict: no way found to steal or lose backer or creator funds through the contract's own logic. 19 attack tests were written, including a 256-run stateful solvency fuzz over tokens with 0, 6 and 77 decimals. Attacks that did not work include: reentrancy from token hooks into every function, a token that returns false or nothing, a token that sends more or less than the amount, ETH pledged to a token campaign and the reverse, claiming the fees of an unused token, the owner touching campaign tokens, disallowing a token mid-campaign, a blacklisted recipient or backer blocking others, zero-decimal dust, and 77-decimal amounts near 2^256.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | Low | A fee recipient equal to the Crowdfund contract or to the token contract itself makes `claimTokenFees` succeed while the tokens end up unreachable. Needs an owner mistake. | The contract can no longer be the recipient, and `claimTokenFees` reverts (`InvalidRecipient`) and keeps the accrual if the recipient is the token itself. Tests flipped to assert the fix. |
| 2 | Note | A token whose `balanceOf` lies can credit a pledge that moved no tokens and take other backers' tokens of the same token. | Cannot be fixed in the contract. Documented: invariants I17 and I19 hold for honest tokens only, so only trusted tokens belong on the allow list. |
| 3 | Note | A token issuer's blacklist can freeze a successful campaign if it blocks the creator, because backers cannot refund a campaign that reached its goal. A token with removed code reverts cleanly. | Documented as the token admin limit. A creator-chosen payout address was considered and left for a later stage. |
| 4 | Note | A token returning a huge payload makes calls on its own campaigns expensive. | The contract reads only 32 bytes, so it adds nothing. Documented. |
| 5 | Note | The owner can allow-list an address with no code or the Crowdfund contract itself. Harmless today, but an empty address could later get code. | Fixed: allowing requires contract code and not the contract itself (`InvalidToken`). Disallowing is always possible. |
| 6 | Note | Rebasing and rounding tokens are unsupported. | Already documented. |

## What changed in the contract after review

- `InvalidRecipient`: the contract cannot be the fee recipient (constructor and `setFeeRecipient`), and `claimTokenFees` refuses a recipient equal to the token.
- `InvalidToken`: allowing a token needs contract code and cannot be the contract itself.

## Quality gates run

- 244 Solidity tests (unit, fuzz, attack, hostile-token, invariant) and 18 TypeScript end-to-end tests pass.
- Eleven invariants now cover ETH and two tokens separately, with exact conservation, per-token fee accounting, currency separation, creation rules and forbidden-action probes. They pass on the default and deep profiles.
- Mutation test (`node scripts/mutation-test.mjs`): the contract is broken in 75 different ways, one at a time, and the suite must fail for every one. Result: 75 of 75 mutants killed (69 in the main run, plus 6 rewritten after the contract refactor).

## What this does not prove

The checks make serious mistakes much less likely. They do not make the contract bug-free, and nobody has independently audited it. The token paths depend on the allow-listed tokens being trustworthy. It must not hold real funds until it has been audited.
