# Stage 2: platform fee and admin controls

Builds on stage 1 (docs/SPEC-01-escrow-core.md). Everything in stage 1 still holds unless this document changes it explicitly. Contract: `contracts/Crowdfund.sol`.

## Goal

Let the platform owner earn a fee on successful campaigns, with strong limits on what the owner can do. The owner earns a fee; the owner never controls campaign funds.

## Roles

- Owner: the platform. Set in the constructor, changed with a two-step transfer (`Ownable2Step`). Renouncing ownership is disabled.
- Fee recipient: the address that receives collected fees. Set by the owner.
- Creator and backer: unchanged from stage 1.

## New state

- `feeBps` (uint16): the fee, in basis points (100 bps = 1%), that applies to campaigns created from now on.
- `feeRecipient` (address, never zero).
- `creationPaused` (bool).
- `accruedFees` (uint256): fees earned and not yet claimed.
- Constants: `MAX_FEE_BPS = 1000` (10%), `BPS = 10_000`.
- Per campaign: `feeBps` (uint16), copied from the global `feeBps` when the campaign is created. It never changes afterwards.

## Functions

`constructor(initialOwner, feeRecipient_, feeBps_)`
- `initialOwner` must not be zero (OpenZeppelin `OwnableInvalidOwner`).
- `feeRecipient_` must not be zero, else `ZeroAddress`. `feeBps_ <= MAX_FEE_BPS`, else `FeeTooHigh`.
- Emits `FeeUpdated(feeBps_)` and `FeeRecipientUpdated(feeRecipient_)`.

`setFee(newFeeBps)` (owner only)
- `newFeeBps <= MAX_FEE_BPS`, else `FeeTooHigh`. Applies only to campaigns created after the call. Emits `FeeUpdated`.

`setFeeRecipient(newRecipient)` (owner only)
- Not zero, else `ZeroAddress`. Applies to all fees not yet claimed. Emits `FeeRecipientUpdated`.

`setCreationPaused(paused)` (owner only)
- Blocks only `createCampaign`. It never affects `pledge`, `withdraw`, `refund` or `claimFees`. Emits `CreationPausedUpdated`.

`createCampaign(goal, deadline, maxFeeBps)` (changed: new third argument)
- `maxFeeBps` is the highest fee the creator accepts. If the current `feeBps` is higher, the call reverts with `FeeAboveMax`. This protects a creator from an owner who raises the fee just before the campaign is created. Pass the fee you were shown, or 1000 to accept anything up to the cap.
- Check order: `CreationPaused`, then `ZeroGoal`, then `InvalidDeadline`, then `FeeAboveMax`.
- Stores the current `feeBps` in the campaign. `CampaignCreated` now also carries `feeBps`.

`withdraw(id)` (changed)
- All stage 1 checks and their order are unchanged.
- `fee = floor(raised * campaign.feeBps / BPS)` (computed with `Math.mulDiv`, so it cannot overflow). `payout = raised - fee`.
- Effects before interaction: `paidOut = true`, `accruedFees += fee`. Then sends exactly `payout` to the creator. If the send fails the whole call reverts and nothing changes.
- `Withdrawn(id, creator, payout, fee)`.
- The fee is not sent to anyone here. Collecting it is a separate step, so a fee recipient that cannot receive ETH can never block a creator.

`claimFees()` (anyone may call)
- `accruedFees > 0`, else `NothingToClaim`.
- Sets `accruedFees = 0` first, then sends the whole amount to the current `feeRecipient`. If the send fails the call reverts. Emits `FeesClaimed(recipient, amount)`. Non-reentrant.
- Anyone can trigger it, but the money only ever goes to `feeRecipient`.

`refund(id)` is unchanged. Refunds are never charged a fee.

`renounceOwnership()` always reverts (`RenounceDisabled`), even while a transfer is pending.

Ownership transfer is two steps (`transferOwnership`, then `acceptOwnership` by the new owner). The pending owner has no rights until it accepts. The owner can cancel a pending transfer by calling `transferOwnership(address(0))`.

Sending ETH: every payout (`withdraw`, `refund`, `claimFees`) is sent with a low-level call that gives the receiver all remaining gas but copies none of its return data. A normal call copies the return data into memory, so a receiver returning megabytes could make the permissionless `claimFees` cost millions of gas. This was found in the stage 2 attack review, fixed, and is tested.

Views added: `feeBps`, `feeRecipient`, `creationPaused`, `accruedFees`, `owner`, `pendingOwner`, and the per-campaign `feeBps` inside `getCampaign`. The field order returned by `getCampaign` is part of the interface and is pinned by a test: `creator`, `deadline`, `feeBps`, `paidOut`, `goal`, `raised`, `refunded` (stage 3 appends an eighth field, `token`, after these). A decoder written for stage 1 must be updated, and the `Withdrawn` and `CampaignCreated` events also gained fields.

## Amendments to stage 1

Stage 1 said there is no owner, that a campaign pays out exactly `raised` to its creator, and that no address other than the creator or a backer can receive a campaign's funds. Stage 2 changes these on purpose:

- There is now an owner, with the limited powers listed here.
- A paid campaign sends `raised - fee` to the creator. The fee stays in the contract as `accruedFees` and is later sent to the fee recipient.
- Stage 1 I3 and I7 now read: only the creator (after success, minus the fee), the backers (after failure) and the fee recipient (for fees only) can ever receive ETH from the contract.

## Invariants (in addition to stage 1)

I1'. Solvency: the contract's ETH balance is at least `accruedFees` plus the sum of what is still owed on every campaign (the stage 1 amounts: `raised` for Active and Succeeded, `raised - refunded` for Failed, 0 for Paid).
I9. Exact split: for every paid campaign, the creator received exactly `raised - fee` and the fee is exactly `floor(raised * feeBps / 10000)`. No wei is lost or created.
I10. Fee cap: every campaign's `feeBps` is at most `MAX_FEE_BPS`, so a creator never pays more than 10%.
I11. Fee snapshot: a campaign's `feeBps` equals the global fee at the moment it was created and never changes afterwards, whatever the owner does later.
I12. Fee accounting: `accruedFees + totalClaimed` equals the sum of the fees of all paid campaigns, and claimed fees went only to the fee recipient.
I13. The owner cannot move campaign funds. The only way ETH reaches the fee side is `claimFees`, which anyone can call, is limited to `accruedFees`, and pays only the current `feeRecipient`. The owner's real lever is `setFeeRecipient`: it can redirect fees that are accrued but not yet claimed (see known limits).
I14. Pausing creation never blocks a pledge, a payout, a refund or a fee claim.
I15. No fee on failure: a failed campaign never adds to `accruedFees`.

## Known limits and trust model

- The owner can change the fee for future campaigns, up to the 10% cap. Creators and backers can read the fee in `getCampaign` before pledging.
- The owner can change the fee recipient at any time, including for fees already accrued but not yet claimed.
- Rounding: the fee rounds down, so the creator receives up to 1 wei more than an exact calculation.
- If the owner loses their key, fees and the pause switch can no longer be managed, and the fee recipient can no longer be changed. Anyone can still call `claimFees`, so unclaimed fees still reach the current recipient. Money in campaigns is unaffected.
- A creator that is a contract unable to receive ETH can never withdraw, and because the goal was reached the backers cannot refund. This only affects that one campaign and is the creator's own doing. A payout-address option may come in a later stage.
- A fee recipient that cannot receive ETH (including the contract itself) makes `claimFees` revert until the owner sets a working recipient. Creators and backers are never affected.
- OpenZeppelin's `acceptOwnership` accepts a call from `address(0)` after a transfer to `address(0)`. No key exists for that address, so this cannot happen on a real chain.
- With `feeBps = 0` the contract behaves exactly like stage 1.
- ETH force-sent to the contract is stuck and counted nowhere, as in stage 1.
