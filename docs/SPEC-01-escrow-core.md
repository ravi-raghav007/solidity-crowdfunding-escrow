# Stage 1: escrow core (native ETH)

Contract: `contracts/Crowdfund.sol`. One contract hosts many all-or-nothing campaigns. Pledges are native ETH. No fee, no admin, no token support (those are later stages).

## Actors

- Creator: any address that calls `createCampaign`. Receives the funds only if the goal is reached.
- Backer: any address that pledges. Gets their full pledge back if the goal is not reached.
- There is no owner, admin or operator. Nobody can move funds except as described below.

## State

Per campaign (ids start at 1; id 0 never exists):

- `creator` (address), `deadline` (uint64 timestamp), `paidOut` (bool)
- `goal` (uint256 wei), `raised` (uint256 wei, total ever pledged), `refunded` (uint256 wei, total refunded so far)

Per campaign and backer: `pledge` (uint256 wei, the amount currently refundable or contributed).

Status is derived, never stored:

- `Active`: `block.timestamp < deadline`
- `Succeeded`: deadline reached, `raised >= goal`, not yet paid out
- `Paid`: deadline reached, `raised >= goal`, `paidOut == true`
- `Failed`: deadline reached, `raised < goal`

## Functions

`createCampaign(goal, deadline) returns (id)`
- `goal > 0`, else revert `ZeroGoal`.
- `deadline >= now + MIN_DURATION` and `deadline <= now + MAX_DURATION` and `deadline <= type(uint64).max`, else revert `InvalidDeadline`. `MIN_DURATION = 1 day`, `MAX_DURATION = 90 days`. Both bounds are inclusive.
- Creator is `msg.sender`. Emits `CampaignCreated(id, creator, goal, deadline)`.

`pledge(id)` payable
- Campaign must exist, else `NoSuchCampaign`.
- `msg.value > 0`, else `ZeroAmount`.
- `now < deadline`, else `CampaignEnded`.
- Adds `msg.value` to `raised` and to the caller's pledge. Emits `Pledged(id, backer, amount)`.
- Over-funding beyond the goal is allowed. The creator may pledge to their own campaign.

`withdraw(id)` (creator only)
- Campaign must exist; caller must be the creator, else `NotCreator`.
- `now >= deadline`, else `NotEnded`. `raised >= goal`, else `GoalNotReached`. Not already paid, else `AlreadyPaid`.
- Sets `paidOut = true` before sending. Sends exactly `raised` wei to the creator. If the send fails the whole call reverts (`TransferFailed`) and nothing changes. Emits `Withdrawn(id, creator, amount)`.
- Non-reentrant.

`refund(id)`
- Campaign must exist. `now >= deadline`, else `NotEnded`. `raised < goal`, else `GoalReached`.
- Caller's pledge must be non-zero, else `NothingToRefund`.
- Sets the caller's pledge to 0 and increases `refunded` before sending. Sends exactly the caller's pledge to the caller. If the send fails the call reverts. Emits `Refunded(id, backer, amount)`.
- Non-reentrant. Anyone with a pledge can refund themselves; nobody can refund on behalf of someone else.

Views: `getCampaign(id)`, `pledgeOf(id, backer)`, `statusOf(id)`, `campaignCount()`, and the public constants `MIN_DURATION` and `MAX_DURATION`. `getCampaign` and `statusOf` revert `NoSuchCampaign` for an unknown id; `pledgeOf` returns 0 for an unknown id.

Revert order is part of the spec and is tested: for every function the checks run in the order listed above (existence first, then the caller or value checks, then the time check, then the goal check, then the already-done check).

`pledge` is intentionally not `nonReentrant`: it makes no external call. If a later stage adds any external call to `pledge` (for example a token transfer), it must be guarded.

The contract has no `receive` or `fallback`. A plain ETH transfer to it reverts.

## Invariants (must hold after every transaction)

I1. Solvency: the contract's ETH balance is at least the sum, over all campaigns, of the ETH still owed: for Active and Succeeded campaigns `raised`; for Failed campaigns `raised - refunded`; for Paid campaigns 0. (ETH force-sent by `selfdestruct` can make the balance higher, never lower.)
I2. Accounting: for every campaign, `raised` equals the sum of all backers' pledges plus `refunded`.
I3. One payout: a campaign pays out at most once, and only to its creator.
I4. Exclusive outcomes: a campaign can never both pay out and refund. `withdraw` needs `raised >= goal`; `refund` needs `raised < goal`; `raised` cannot change after the deadline, so the outcome is fixed at the deadline.
I5. No late pledges: nothing can be pledged at or after the deadline.
I6. Fair refunds: a backer can recover at most what they pledged, exactly once, and only when the campaign failed.
I7. No privileged access: no address other than the creator (after success) or a backer (after failure) can ever receive a campaign's funds.
I8. Boundary: at `block.timestamp == deadline` pledging is closed and `withdraw`/`refund` are open.

## Known limits and trust model (accepted for stage 1)

- Miners or validators can shift `block.timestamp` slightly. The deadline boundary can move by seconds. Documented, not mitigated.
- A creator whose address cannot receive ETH can never withdraw (their own funds stay locked, nobody else's). Documented. A payout-address option may come later.
- A campaign has no cancel function. Immutable by design.
- ETH force-sent to the contract is stuck and counted nowhere.
- The contract cannot tell a creator's second wallet from a real backer. A creator can top up their own campaign, even in the last second, to reach the goal with their own money and then withdraw it. Nothing is stolen (the creator only recovers their own money), but backers who want "funded by others" must judge that off-chain. Forbidding self-pledges was considered and rejected: it adds code but cannot be enforced against a second wallet.
- A creator can choose a trivially small goal (even 1 wei). Such a campaign always "succeeds" and pays the creator everything pledged. This is a trust decision for backers, and the user interface should show the goal clearly.
- `pledge` ignores whether the amount is large or small beyond non-zero. No per-backer limits.
