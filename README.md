# Solidity crowdfunding escrow

An all-or-nothing crowdfunding escrow in Solidity, with a platform fee, ETH and ERC-20 pledges, and a test suite that attacks it.

Designed, specified, tested and deployed by me. This repository is the escrow contract with its tests, specifications and review notes. The wider system (installment payouts with a backer vote, reward tokens and a Laravel integration) is available for review on request.

## What the contract does

- A creator opens a campaign with a goal and a deadline.
- Backers pledge ETH, or an approved ERC-20 token.
- If the goal is reached by the deadline, the creator collects the money minus a platform fee.
- If it is not, every backer takes back exactly what they pledged. No one can block that.
- The platform owner can set the fee for **new** campaigns (hard cap of 10 percent in the code), approve tokens, pause the creation of new campaigns and claim fees that have already accrued. No function lets the owner move pledged money.

## Design decisions

| Risk | Decision |
|---|---|
| Reentrancy through a recipient or token hook | Checks-effects-interactions plus `nonReentrant` on every function that moves value. Tests assert the exact guard error. Removing the guard on purpose makes the suite fail. |
| Owner raises the fee just before a creator creates a campaign | The creator passes the highest fee they accept in their own transaction. |
| Return bomb (a recipient answers with megabytes of data to burn gas) | The ETH send copies no return data. A broken copy that copies it again is caught by the mutation tests. |
| Odd or hostile tokens | Token allow-list, a balance check that rejects any token delivering a different amount than requested, and tests with tokens that return false, return nothing, hook back in, self-destruct, or use 0, 6 and 77 decimals. |
| Forced ETH or donations skewing accounting | Payouts and refunds come from recorded pledges, never from the contract balance. |
| Overflow in fee math | `Math.mulDiv` and tests with enormous amounts. |

`pledge` (ETH) makes no external call, so it is deliberately not guarded. That choice is written in `docs/SPEC-01-escrow-core.md`.

## Tests

```
npm install
npx hardhat test
```

**262 passing: 244 Solidity tests and 18 TypeScript end-to-end tests.**

- Attack tests: reentrancy (including cross-function and cross-campaign), front running by the owner, return bombs, hostile tokens, forced ETH, huge amounts, rejecting and gas-burning recipients.
- Invariant tests: random sequences of actions, checked against an independent calculation.
- Mutation tests: `node scripts/mutation-test.mjs` breaks the contract in 75 different ways, one at a time. The suite must fail for every one.
- Deeper fuzzing: `npx hardhat test --test-profile deep` (2048 fuzz runs, 256 invariant runs).

## Layout

```
contracts/Crowdfund.sol          the escrow
contracts/*.t.sol                Solidity tests (unit, attack, fee, token, invariant)
contracts/helpers/TestTokens.sol hostile and odd token mocks used by the tests
test/*.ts                        end-to-end tests with ethers
scripts/mutation-test.mjs        mutation testing
docs/SPEC-*.md                   written specifications
docs/REVIEW-*.md                 review rounds, each finding and how it was resolved
ignition/modules/Crowdfund.ts    deployment
```

## Deployment

Deployed to Ethereum Sepolia with Hardhat Ignition:
[0x504d6Cd355e6C79c35003A416181b88E7732Ee7d](https://sepolia.etherscan.io/address/0x504d6Cd355e6C79c35003A416181b88E7732Ee7d)

To deploy your own:

```
npx hardhat keystore set SEPOLIA_RPC_URL
npx hardhat keystore set SEPOLIA_PRIVATE_KEY
npx hardhat ignition deploy ignition/modules/Crowdfund.ts --network sepolia
```

Solidity 0.8.34, OpenZeppelin 5, Hardhat 3, ethers 6.

## Status

The contract has been through three written review rounds and extensive automated testing. It has not had an independent audit, which should happen before any real funds are involved.
