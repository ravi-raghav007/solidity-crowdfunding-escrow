# Stage 3: ERC-20 pledges

Builds on stages 1 and 2 (docs/SPEC-01-escrow-core.md, docs/SPEC-02-fee-and-admin.md). The money rules for ETH campaigns are unchanged. A few interface details did change, and they are listed in "Amendments to stages 1 and 2" below. Contract: `contracts/Crowdfund.sol`.

## Goal

Let a campaign be funded in an ERC-20 token (for example a stablecoin) instead of ETH. A campaign uses exactly one currency, chosen when it is created. The all-or-nothing rules, the fee rules and the safety rules are the same for tokens.

## Design choices

- The ETH money rules are not changed. Token campaigns get their own entry points, so everything already tested for ETH keeps its meaning.
- Tokens are owner-curated. Only tokens on an allow list can be used for new campaigns. This keeps hostile or unusual tokens (rebasing, fee-on-transfer, malicious hooks) out of the system.
- Removing a token from the allow list never traps funds. Existing campaigns in that token keep working: pledges, payouts, refunds and fee claims continue.
- Tokens that take a cut on transfer are rejected at pledge time (the contract checks that exactly the pledged amount arrived).
- All token transfers use OpenZeppelin `SafeERC20`, so tokens that return nothing (like USDT) or return `false` are handled.
- The amount unit is the token's smallest unit (for a 6-decimals token, 1_000_000 is one token). The goal, `raised`, `refunded` and fee maths are the same integer maths as for ETH.

## New state

- `allowedToken[token]` (bool).
- `accruedTokenFees[token]` (uint256): token fees earned and not yet claimed.
- Per campaign: `token` (address, `address(0)` means ETH). It is added as the LAST field of the `Campaign` struct, so the field order of stages 1 and 2 is unchanged.

## Functions

`setTokenAllowed(token, allowed)` (owner only)
- `token != address(0)`, else `ZeroAddress`.
- When allowing (`allowed == true`), `token` must have contract code and must not be this contract, else `InvalidToken`. This blocks listing an empty address or the Crowdfund contract by mistake. It does not prove the token is a well-behaved ERC-20, and the code check is made only at the moment of listing. Disallowing is always possible for any address.
- Affects only campaigns created afterwards. Emits `TokenAllowedUpdated(token, allowed)`.

`createTokenCampaign(goal, deadline, maxFeeBps, token)`
- Same checks and order as `createCampaign` (`CreationPaused`, `ZeroGoal`, `InvalidDeadline`, `FeeAboveMax`), then `TokenNotAllowed` if the token is not on the allow list (this also rejects `address(0)`).
- Stores the token. `CampaignCreated` now ends with the token (it is `address(0)` for ETH campaigns).

`createCampaign(goal, deadline, maxFeeBps)` is unchanged and creates an ETH campaign.

`pledgeToken(id, amount)` (non-payable, non-reentrant)
- Campaign must exist (`NoSuchCampaign`), be a token campaign (`WrongCurrency`), `amount > 0` (`ZeroAmount`), and not be ended (`CampaignEnded`).
- Pulls `amount` tokens from the caller with `safeTransferFrom` (the caller must have approved the contract). Then checks that the contract's token balance grew by exactly `amount`, else `UnsupportedToken`.
- Adds `amount` to `raised` and to the caller's pledge. Emits `Pledged`.

`pledge(id)` (ETH) additionally reverts `WrongCurrency` if the campaign is a token campaign. The check goes right after the existence check.

`withdraw(id)`
- Unchanged checks and order. For a token campaign it sends `raised - fee` tokens to the creator with `safeTransfer`, and adds the fee to `accruedTokenFees[token]` instead of `accruedFees`. A failing token transfer reverts the whole call.

`refund(id)`
- Unchanged checks and order. For a token campaign it returns the caller's pledge in tokens.

`claimTokenFees(token)` (anyone may call, non-reentrant)
- `accruedTokenFees[token] > 0`, else `NothingToClaim`. Clears it first, then sends the whole amount to the current `feeRecipient` with `safeTransfer`. Emits `TokenFeesClaimed(token, recipient, amount)`.
- Works whether or not the token is still on the allow list.
- If the current `feeRecipient` is the token contract itself, reverts with `InvalidRecipient` and keeps the accrued fees, because tokens sent to their own contract are usually unrecoverable. The owner can set a different recipient and claim again.

`setFeeRecipient(newRecipient)` and the constructor (stage 2) now also revert with `InvalidRecipient` if the recipient is the Crowdfund contract itself. Fees sent to the contract would be stranded there (found in the stage 3 review). The check order is: owner, then `ZeroAddress`, then `InvalidRecipient`.

`claimFees()` is unchanged (ETH fees only).

## Amendments to stages 1 and 2

- `pledge(id)` (ETH) gained a currency check: after the existence check it reverts `WrongCurrency` if the campaign is a token campaign. The check order is existence, currency, zero value, ended.
- The `CampaignCreated` event gained a last argument, `token` (`address(0)` for ETH campaigns). Event decoders written for stage 2 must be updated.
- `getCampaign` now returns eight fields: `creator`, `deadline`, `feeBps`, `paidOut`, `goal`, `raised`, `refunded`, `token`. The first seven are in the stage 2 order, so a stage 2 decoder keeps working if it ignores trailing data. A test pins the eighth.
- Stage 2's statement that the fee recipient may be any non-zero address is replaced by the `InvalidRecipient` rule above.
- `pledge` (ETH) is still not `nonReentrant`: it makes no external call and only touches ETH-campaign state, so a hostile token hook that calls it while `pledgeToken` holds the guard cannot break any accounting. If it ever gains an external call, it must be guarded.

## Invariants (in addition to stages 1 and 2)

I16. Currency separation: an ETH campaign never holds or pays tokens, and a token campaign never holds or pays ETH. A campaign's `token` never changes.
I17. Token solvency: for every token, the contract's token balance is at least `accruedTokenFees[token]` plus the token amounts still owed on that token's campaigns (the same per-status amounts as for ETH).
I18. Token conservation: with no tokens sent to the contract directly, the contract's balance of a token equals tokens pledged minus tokens paid out, refunded or claimed.
I19. Exact received: a token pledge only succeeds if exactly the pledged amount arrived. `raised` therefore always equals what the contract really received.
I20. The same exact-split, fee-cap, fee-snapshot and no-fee-on-failure rules hold for token campaigns (I9 to I15, applied per token).
I21. Allow-list scope: only tokens on the allow list at creation time can start a campaign, and later changes to the list never block pledges, payouts, refunds or fee claims of existing campaigns.
I22. The owner cannot move campaign tokens. The only way tokens reach the fee side is `claimTokenFees`, limited to `accruedTokenFees[token]`, paid to `feeRecipient`.

## Known limits and trust model

- The owner decides which tokens are allowed, and the contract can only be as safe as those tokens. Invariants I17 and I19 hold for honest tokens. A token whose `balanceOf` lies, or that mints or burns balances behind the contract's back, can credit a pledge that moved no tokens and so take other backers' tokens of that same token (confirmed by a test, damage limited to that token). Only list tokens whose issuer you trust and that behave like plain ERC-20 tokens.
- A token's own admin can freeze funds. If the issuer blacklists a creator, that creator's `withdraw` reverts, and because the goal was reached the backers of that campaign cannot refund either, so the pledges stay stuck until the issuer lifts the block. A blacklisted backer only blocks their own refund. A token whose code disappears makes its campaigns' payouts and refunds revert cleanly with state rolled back. A creator-chosen payout address was considered and left for a later stage.
- A token whose transfers burn a lot of gas (including one that returns a huge payload from `transfer`) makes calls on that token's own campaigns expensive. The contract reads only 32 bytes of return data, so it adds no extra cost of its own, and other tokens are not affected.
- Rebasing tokens (balances that change by themselves) are not supported and must not be allow-listed.
- Tokens sent directly to the contract (not through `pledgeToken`) are stuck and counted nowhere, like forced ETH.
- A token transfer to a blacklisted creator or backer reverts. For a backer that only blocks their own refund; for a creator it blocks their own payout.
- ERC-777 style hooks are blocked from re-entering by the reentrancy guard, but ERC-777 tokens should still not be allow-listed.
- A fee recipient equal to a token's own address is refused for that token (`InvalidRecipient`) but cannot be ruled out in general for other cases (for example a recipient that is a contract unable to forward tokens). Tokens sent to such an address are lost to the owner, never to backers or creators.
