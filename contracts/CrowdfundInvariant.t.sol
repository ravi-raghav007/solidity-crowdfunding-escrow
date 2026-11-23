// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {MockToken} from "./helpers/TestTokens.sol";

/// Drives random but bounded sequences of actions against the contract (as backers, creators and the
/// owner, with both ETH and token campaigns) and keeps its own independent record ("ghost" variables)
/// of every movement of ETH and of tokens, so the invariants can compare the contract's state with what
/// actually happened. Money is tracked per currency: address(0) means ETH, otherwise the token address.
contract Handler is Test {
    Crowdfund public cf;
    MockToken public token;
    MockToken public token2;
    address public owner;
    address[] public actors;
    uint256[] public ids;

    // ghost state: money, per currency
    mapping(address cur => uint256) public totalIn; // entered through successful pledges
    mapping(address cur => uint256) public totalOut; // left through withdraw, refund or fee claims
    mapping(address cur => uint256) public claimedByContract; // fees as seen leaving the contract
    mapping(address cur => uint256) public claimedByRecipient; // fees as seen arriving at the recipient
    mapping(address cur => uint256) public feeSum; // fees of all paid campaigns, computed independently
    // ghost state: counters
    uint256 public pledgeOk;
    uint256 public withdrawOk;
    uint256 public refundOk;
    uint256 public claimOk;
    uint256 public tokenCampaigns;
    bool public capBroken; // set if the owner ever managed to set a fee above the cap
    bool public accessBroken; // set if any forbidden action ever succeeded

    mapping(uint256 id => uint256) public pledgedTotal;
    mapping(uint256 id => mapping(address actor => uint256)) public pledgedBy;
    mapping(uint256 id => mapping(address actor => uint256)) public refundedTo;
    mapping(uint256 id => uint256) public paidToCreator;
    mapping(uint256 id => uint256) public feeOf;
    mapping(uint256 id => uint16) public feeAtCreation;
    mapping(uint256 id => uint16) public maxFeeAtCreation;
    mapping(uint256 id => address) public currencyOf;
    mapping(uint256 id => uint256) public raisedAtEnd;
    mapping(uint256 id => bool) public endSeen;

    constructor(Crowdfund _cf, address _owner, MockToken _token, MockToken _token2) {
        cf = _cf;
        owner = _owner;
        token = _token;
        token2 = _token2;
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _bal(address cur, address who) internal view returns (uint256) {
        return cur == address(0) ? who.balance : MockToken(cur).balanceOf(who);
    }

    // -------------------------------------------------------------- campaign actions

    function create(uint256 actorSeed, uint256 goal, uint256 duration, uint256 maxFeeSeed, uint256 useToken)
        external
    {
        address actor = actors[actorSeed % actors.length];
        goal = bound(goal, 1, 100 ether);
        duration = bound(duration, 1 days, 90 days);
        uint16 maxFee = uint16(bound(maxFeeSeed, 0, 1000));
        uint16 feeNow = cf.feeBps(); // read before pranking
        uint256 deadline = block.timestamp + duration;
        uint256 pick = useToken % 3; // 0: token, 1: ETH, 2: second token
        address cur = pick == 0 ? address(token) : (pick == 2 ? address(token2) : address(0));
        bool paused = cf.creationPaused();
        bool allowed = cur == address(0) || cf.allowedToken(cur);
        vm.prank(actor);
        if (cur != address(0)) {
            try cf.createTokenCampaign(goal, deadline, maxFee, cur) returns (uint256 id) {
                if (paused || !allowed) accessBroken = true; // created while paused, or with a disallowed token
                _registerCampaign(id, feeNow, maxFee, cur);
                tokenCampaigns++;
            } catch {}
        } else {
            try cf.createCampaign(goal, deadline, maxFee) returns (uint256 id) {
                if (paused) accessBroken = true; // created while paused
                _registerCampaign(id, feeNow, maxFee, address(0));
            } catch {}
        }
    }

    function _registerCampaign(uint256 id, uint16 feeNow, uint16 maxFee, address cur) internal {
        ids.push(id);
        feeAtCreation[id] = feeNow;
        maxFeeAtCreation[id] = maxFee;
        currencyOf[id] = cur;
    }

    function pledge(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        if (ids.length == 0) return;
        _doPledge(actors[actorSeed % actors.length], ids[idSeed % ids.length], bound(amount, 1, 60 ether));
    }

    /// Guided action: pledge exactly what is missing to reach the goal (plus a little extra half the time),
    /// so the fuzzer regularly produces successful campaigns instead of waiting for luck.
    function fundToGoal(uint256 actorSeed, uint256 idSeed, uint256 extra) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        Crowdfund.Campaign memory c = cf.getCampaign(id);
        if (block.timestamp >= c.deadline || c.raised >= c.goal) return;
        uint256 amount = c.goal - c.raised;
        if (extra % 2 == 0) amount += bound(extra, 0, 5 ether);
        _doPledge(actors[actorSeed % actors.length], id, amount);
    }

    function _doPledge(address actor, uint256 id, uint256 amount) internal {
        address cur = currencyOf[id];
        if (cur == address(0)) {
            vm.deal(actor, actor.balance + amount);
            vm.prank(actor);
            try cf.pledge{value: amount}(id) {
                _recordPledge(cur, id, actor, amount);
            } catch {}
        } else {
            MockToken t = MockToken(cur);
            t.mint(actor, amount);
            vm.prank(actor);
            t.approve(address(cf), amount);
            vm.prank(actor);
            try cf.pledgeToken(id, amount) {
                _recordPledge(cur, id, actor, amount);
            } catch {}
        }
    }

    function _recordPledge(address cur, uint256 id, address actor, uint256 amount) internal {
        totalIn[cur] += amount;
        pledgedTotal[id] += amount;
        pledgedBy[id][actor] += amount;
        pledgeOk++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 0, 40 days);
        vm.warp(block.timestamp + secs);
        _snapshotEnds();
    }

    /// Guided action: jump to the deadline of one campaign, so payouts and refunds become possible.
    function warpToDeadline(uint256 idSeed) external {
        if (ids.length == 0) return;
        Crowdfund.Campaign memory c = cf.getCampaign(ids[idSeed % ids.length]);
        if (block.timestamp < c.deadline) vm.warp(c.deadline);
        _snapshotEnds();
    }

    function _snapshotEnds() internal {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            if (!endSeen[id] && block.timestamp >= c.deadline) {
                endSeen[id] = true;
                raisedAtEnd[id] = c.raised;
            }
        }
    }

    function withdraw(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        Crowdfund.Campaign memory c = cf.getCampaign(id);
        address cur = c.token;
        uint256 creatorBefore = _bal(cur, c.creator);
        uint256 contractBefore = _bal(cur, address(cf));
        vm.prank(c.creator);
        try cf.withdraw(id) {
            paidToCreator[id] += _bal(cur, c.creator) - creatorBefore;
            totalOut[cur] += contractBefore - _bal(cur, address(cf)); // the payout only; the fee stays inside
            uint256 fee = (c.raised * c.feeBps) / 10_000; // independent of Math.mulDiv
            feeOf[id] = fee;
            feeSum[cur] += fee;
            withdrawOk++;
        } catch {}
    }

    function refund(uint256 actorSeed, uint256 idSeed) external {
        if (ids.length == 0) return;
        address actor = actors[actorSeed % actors.length];
        uint256 id = ids[idSeed % ids.length];
        address cur = currencyOf[id];
        uint256 actorBefore = _bal(cur, actor);
        uint256 contractBefore = _bal(cur, address(cf));
        vm.prank(actor);
        try cf.refund(id) {
            refundedTo[id][actor] += _bal(cur, actor) - actorBefore;
            totalOut[cur] += contractBefore - _bal(cur, address(cf));
            refundOk++;
        } catch {}
    }

    // -------------------------------------------------------------- owner and fee actions

    function setFee(uint256 bps) external {
        bps = bound(bps, 0, 1000);
        vm.prank(owner);
        cf.setFee(uint16(bps));
    }

    /// The owner tries to set a fee above the cap. It must always fail.
    function setFeeTooHigh(uint256 bps) external {
        bps = bound(bps, 1001, type(uint16).max);
        vm.prank(owner);
        try cf.setFee(uint16(bps)) {
            capBroken = true;
        } catch {}
    }

    function setRecipient(uint256 actorSeed) external {
        vm.prank(owner);
        cf.setFeeRecipient(actors[actorSeed % actors.length]);
    }

    function setPaused(bool paused) external {
        vm.prank(owner);
        cf.setCreationPaused(paused);
    }

    /// The owner allows or disallows the token. Existing token campaigns must be unaffected.
    function setTokenAllowed(bool allowed, uint256 which) external {
        vm.prank(owner);
        cf.setTokenAllowed(which % 2 == 0 ? address(token) : address(token2), allowed);
    }

    function claim(uint256 callerSeed) external {
        address caller = actors[callerSeed % actors.length];
        address recipient = cf.feeRecipient();
        uint256 recipientBefore = recipient.balance;
        uint256 contractBefore = address(cf).balance;
        vm.prank(caller);
        try cf.claimFees() {
            uint256 sent = contractBefore - address(cf).balance;
            claimedByContract[address(0)] += sent;
            claimedByRecipient[address(0)] += recipient.balance - recipientBefore;
            totalOut[address(0)] += sent;
            claimOk++;
        } catch {}
    }

    function claimTokens(uint256 callerSeed, uint256 which) external {
        address caller = actors[callerSeed % actors.length];
        MockToken t = which % 2 == 0 ? token : token2;
        address recipient = cf.feeRecipient();
        uint256 recipientBefore = t.balanceOf(recipient);
        uint256 contractBefore = t.balanceOf(address(cf));
        vm.prank(caller);
        try cf.claimTokenFees(address(t)) {
            uint256 sent = contractBefore - t.balanceOf(address(cf));
            claimedByContract[address(t)] += sent;
            claimedByRecipient[address(t)] += t.balanceOf(recipient) - recipientBefore;
            totalOut[address(t)] += sent;
            claimOk++;
        } catch {}
    }

    // -------------------------------------------------------------- forbidden actions (must always fail)

    /// A non-owner tries every owner-only function.
    function attackAdmin(uint256 actorSeed, uint256 which, uint256 value) external {
        address attacker = actors[actorSeed % actors.length];
        which = which % 5;
        vm.prank(attacker);
        if (which == 0) {
            try cf.setFee(uint16(bound(value, 0, 1000))) {
                accessBroken = true;
            } catch {}
        } else if (which == 1) {
            try cf.setFeeRecipient(attacker) {
                accessBroken = true;
            } catch {}
        } else if (which == 2) {
            try cf.setCreationPaused(true) {
                accessBroken = true;
            } catch {}
        } else if (which == 3) {
            try cf.transferOwnership(attacker) {
                accessBroken = true;
            } catch {}
        } else {
            try cf.setTokenAllowed(value % 4 < 2 ? address(token) : address(token2), value % 2 == 0) {
                accessBroken = true;
            } catch {}
        }
    }

    /// Someone other than the creator tries to withdraw.
    function attackWithdraw(uint256 actorSeed, uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[idSeed % ids.length];
        address creator = cf.getCampaign(id).creator;
        address attacker = actors[actorSeed % actors.length];
        if (attacker == creator) return;
        vm.prank(attacker);
        try cf.withdraw(id) {
            accessBroken = true;
        } catch {}
    }

    /// Zero-value pledges and zero-goal campaigns must always be rejected.
    function attackZero(uint256 actorSeed, uint256 idSeed) external {
        address attacker = actors[actorSeed % actors.length];
        if (ids.length > 0) {
            uint256 id = ids[idSeed % ids.length];
            if (currencyOf[id] == address(0)) {
                vm.prank(attacker);
                try cf.pledge{value: 0}(id) {
                    accessBroken = true;
                } catch {}
            } else {
                vm.prank(attacker);
                try cf.pledgeToken(id, 0) {
                    accessBroken = true;
                } catch {}
            }
        }
        uint256 deadline = block.timestamp + 2 days;
        vm.prank(attacker);
        try cf.createCampaign(0, deadline, 1000) {
            accessBroken = true;
        } catch {}
    }

    /// Paying a campaign in the wrong currency must always be rejected.
    function attackCurrency(uint256 actorSeed, uint256 idSeed, uint256 amount) external {
        if (ids.length == 0) return;
        address actor = actors[actorSeed % actors.length];
        uint256 id = ids[idSeed % ids.length];
        amount = bound(amount, 1, 10 ether);
        if (currencyOf[id] == address(0)) {
            token.mint(actor, amount);
            vm.prank(actor);
            token.approve(address(cf), amount);
            vm.prank(actor);
            try cf.pledgeToken(id, amount) {
                accessBroken = true;
            } catch {}
        } else {
            vm.deal(actor, actor.balance + amount);
            vm.prank(actor);
            try cf.pledge{value: amount}(id) {
                accessBroken = true;
            } catch {}
        }
    }
}

contract CrowdfundInvariantTest is Test {
    Crowdfund cf;
    Handler handler;
    MockToken token;
    MockToken token2;
    address owner = makeAddr("owner");

    function setUp() public {
        cf = new Crowdfund(owner, makeAddr("initialRecipient"), 800);
        token = new MockToken("Mock", "MCK", 18);
        token2 = new MockToken("Mock Two", "MK2", 6);
        vm.startPrank(owner);
        cf.setTokenAllowed(address(token), true);
        cf.setTokenAllowed(address(token2), true);
        vm.stopPrank();
        handler = new Handler(cf, owner, token, token2);
        targetContract(address(handler));
    }

    /// I1' and I17: the contract always holds at least what it owes, in each currency separately.
    function invariant_Solvency() public view {
        uint256 ethOwed = cf.accruedFees();
        uint256 tokenOwed = cf.accruedTokenFees(address(token));
        uint256 token2Owed = cf.accruedTokenFees(address(token2));
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            Crowdfund.Status s = cf.statusOf(id);
            uint256 owed;
            if (s == Crowdfund.Status.Failed) owed = c.raised - c.refunded;
            else if (s != Crowdfund.Status.Paid) owed = c.raised;
            if (c.token == address(0)) ethOwed += owed;
            else if (c.token == address(token)) tokenOwed += owed;
            else token2Owed += owed;
        }
        assertGe(address(cf).balance, ethOwed, "contract is insolvent in ETH");
        assertGe(token.balanceOf(address(cf)), tokenOwed, "contract is insolvent in token one");
        assertGe(token2.balanceOf(address(cf)), token2Owed, "contract is insolvent in token two");
    }

    /// I18 (exact form): in each currency, the balance is what came in minus what went out through payouts,
    /// refunds and fee claims. No ETH or token leaves any other way (covers I13 and I22 as well).
    function invariant_Conservation() public view {
        assertEq(address(cf).balance, handler.totalIn(address(0)) - handler.totalOut(address(0)), "ETH mismatch");
        assertEq(
            token.balanceOf(address(cf)),
            handler.totalIn(address(token)) - handler.totalOut(address(token)),
            "token one mismatch"
        );
        assertEq(
            token2.balanceOf(address(cf)),
            handler.totalIn(address(token2)) - handler.totalOut(address(token2)),
            "token two mismatch"
        );
    }

    /// I2: raised equals the sum of live pledges plus what was refunded, and equals the ghost total.
    function invariant_Accounting() public view {
        uint256 n = handler.idCount();
        uint256 a = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            uint256 sum;
            for (uint256 j = 0; j < a; j++) {
                sum += cf.pledgeOf(id, handler.actors(j));
            }
            assertEq(sum + c.refunded, c.raised, "pledges do not add up");
            assertEq(c.raised, handler.pledgedTotal(id), "raised differs from successful pledges");
        }
    }

    /// Stage 1 I3 and I4: payouts only after success, refunds only after failure, never both.
    function invariant_ExclusiveOutcomes() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            Crowdfund.Campaign memory c = cf.getCampaign(handler.ids(i));
            if (c.paidOut) {
                assertGe(c.raised, c.goal, "paid out without reaching goal");
                assertEq(c.refunded, 0, "paid out and refunded");
            }
            if (c.refunded > 0) {
                assertLt(c.raised, c.goal, "refunded although goal reached");
                assertFalse(c.paidOut, "refunded and paid out");
            }
        }
    }

    /// I9 and I20: the creator received exactly raised minus the exact fee, once, and nothing unless paid out.
    function invariant_ExactSplit() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            if (c.paidOut) {
                uint256 fee = (c.raised * c.feeBps) / 10_000;
                assertEq(handler.feeOf(id), fee, "fee differs from floor(raised * bps / 10000)");
                assertEq(handler.paidToCreator(id), c.raised - fee, "creator did not get raised minus fee");
            } else {
                assertEq(handler.paidToCreator(id), 0, "creator paid without paidOut");
                assertEq(handler.feeOf(id), 0, "fee booked on an unpaid campaign");
            }
        }
    }

    /// I10, I11 and I16: every campaign's fee is within the cap and is exactly the fee in force at creation,
    /// and a campaign's currency never changes.
    function invariant_FeeSnapshotCapAndCurrency() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            assertLe(c.feeBps, cf.MAX_FEE_BPS(), "campaign fee above cap");
            assertEq(c.feeBps, handler.feeAtCreation(id), "campaign fee changed after creation");
            assertLe(c.feeBps, handler.maxFeeAtCreation(id), "campaign created above the creator limit");
            assertEq(c.token, handler.currencyOf(id), "campaign currency changed");
        }
        assertLe(cf.feeBps(), cf.MAX_FEE_BPS(), "global fee above cap");
        assertFalse(handler.capBroken(), "owner managed to set a fee above the cap");
    }

    /// I12 and I15, per currency: unclaimed plus claimed fees equal the fees of paid campaigns, and the money
    /// that left the contract as fees arrived at the fee recipient.
    function invariant_FeeAccounting() public view {
        assertEq(cf.accruedFees() + handler.claimedByContract(address(0)), handler.feeSum(address(0)), "ETH fees");
        assertEq(
            handler.claimedByContract(address(0)), handler.claimedByRecipient(address(0)), "ETH fees went elsewhere"
        );
        address t = address(token);
        assertEq(cf.accruedTokenFees(t) + handler.claimedByContract(t), handler.feeSum(t), "token fees");
        assertEq(handler.claimedByContract(t), handler.claimedByRecipient(t), "token fees went elsewhere");
        address t2 = address(token2);
        assertEq(cf.accruedTokenFees(t2) + handler.claimedByContract(t2), handler.feeSum(t2), "token two fees");
        assertEq(handler.claimedByContract(t2), handler.claimedByRecipient(t2), "token two fees went elsewhere");
    }

    /// Forbidden actions (non-owner admin calls, non-creator withdraws, zero pledges, zero goals, wrong currency)
    /// never succeed.
    function invariant_AccessControlHolds() public view {
        assertFalse(handler.accessBroken(), "a forbidden action succeeded");
    }

    /// I13 and I22: the owner never receives ETH or tokens, because no function can send campaign money to it.
    function invariant_OwnerNeverReceivesAnything() public view {
        assertEq(owner.balance, 0, "the owner received ETH");
        assertEq(token.balanceOf(owner), 0, "the owner received tokens");
        assertEq(token2.balanceOf(owner), 0, "the owner received token two");
    }

    /// I5: `raised` never changes once the deadline has passed.
    function invariant_RaisedFrozenAfterDeadline() public view {
        uint256 n = handler.idCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            if (handler.endSeen(id)) {
                assertEq(cf.getCampaign(id).raised, handler.raisedAtEnd(id), "raised changed after deadline");
            }
        }
    }

    /// I6: a backer recovers at most what they pledged, and nothing at all from a successful campaign.
    function invariant_RefundsBoundedByPledges() public view {
        uint256 n = handler.idCount();
        uint256 a = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 id = handler.ids(i);
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            for (uint256 j = 0; j < a; j++) {
                address actor = handler.actors(j);
                uint256 refunded = handler.refundedTo(id, actor);
                uint256 pledged = handler.pledgedBy(id, actor);
                assertLe(refunded, pledged, "refunded more than pledged");
                assertEq(refunded + cf.pledgeOf(id, actor), pledged, "backer balance does not reconcile");
                if (c.raised >= c.goal) assertEq(refunded, 0, "refund paid on a successful campaign");
            }
        }
    }

    // ------------------------------------------------------------------ the handler must be able to reach everything

    /// The fuzzer is only meaningful if its handler can reach every path. This scripted run proves a payout,
    /// a refund and a fee claim are all reachable, for ETH and for tokens.
    function test_HandlerReachesPayoutRefundAndClaim() public {
        // ETH: campaign 1 succeeds, campaign 2 fails
        handler.create(0, 5 ether, 2 days, 1000, 1);
        handler.pledge(1, 0, 6 ether);
        handler.create(2, 50 ether, 2 days, 1000, 1);
        handler.pledge(3, 1, 1 ether);
        // tokens: campaign 3 succeeds, campaign 4 fails
        handler.create(0, 5 ether, 2 days, 1000, 0);
        handler.pledge(1, 2, 6 ether);
        handler.create(2, 50 ether, 2 days, 1000, 0);
        handler.pledge(3, 3, 1 ether);

        handler.warp(3 days);
        handler.withdraw(0);
        handler.refund(3, 1);
        handler.claim(4);
        handler.withdraw(2);
        handler.refund(3, 3);
        handler.claimTokens(4, 0);

        assertEq(handler.pledgeOk(), 4);
        assertEq(handler.withdrawOk(), 2);
        assertEq(handler.refundOk(), 2);
        assertEq(handler.claimOk(), 2);
        assertEq(handler.tokenCampaigns(), 2);
        assertEq(address(cf).balance, 0);
        assertEq(token.balanceOf(address(cf)), 0);
        assertEq(handler.feeSum(address(0)), 0.48 ether); // 8% of 6 ether
        assertEq(handler.feeSum(address(token)), 0.48 ether);
    }

    /// I14: pausing creation does not block pledges, payouts, refunds or fee claims. I21: disallowing the token
    /// does not block anything on an existing token campaign.
    function test_PauseAndDisallowDoNotBlockExistingCampaigns() public {
        handler.create(0, 5 ether, 2 days, 1000, 0); // token campaign
        handler.pledge(1, 0, 6 ether);
        handler.create(2, 50 ether, 2 days, 1000, 0); // token campaign that will fail
        handler.pledge(3, 1, 1 ether);

        handler.setPaused(true);
        handler.setTokenAllowed(false, 0);
        handler.create(4, 1 ether, 2 days, 1000, 0); // must fail: paused and not allowed
        assertEq(handler.idCount(), 2);
        handler.pledge(2, 0, 1 ether); // still works

        handler.warp(3 days);
        handler.withdraw(0);
        handler.refund(3, 1);
        handler.claimTokens(4, 0);

        assertEq(handler.withdrawOk(), 1);
        assertEq(handler.refundOk(), 1);
        assertEq(handler.claimOk(), 1);
        assertEq(handler.pledgeOk(), 3);
    }

    /// The second token is reachable too: a payout, a refund and a fee claim in token two, kept apart from token one.
    function test_SecondTokenIsReachableAndSeparate() public {
        handler.create(0, 5 ether, 2 days, 1000, 2); // token two, will succeed
        handler.pledge(1, 0, 6 ether);
        handler.create(2, 50 ether, 2 days, 1000, 0); // token one, will fail
        handler.pledge(3, 1, 1 ether);

        handler.warp(3 days);
        handler.withdraw(0);
        handler.refund(3, 1);
        handler.claimTokens(4, 1); // token two

        assertEq(handler.feeSum(address(token2)), 0.48 ether);
        assertEq(handler.feeSum(address(token)), 0);
        assertEq(token2.balanceOf(address(cf)), 0);
        assertEq(token.balanceOf(address(cf)), 0);
        assertEq(token2.balanceOf(handler.actors(0)), 5.52 ether); // the creator, 6 minus 8%
    }

    /// A campaign cannot be created while creation is paused, or in a token that is not allowed.
    function test_CreationRulesAreEnforced() public {
        handler.setPaused(true);
        handler.create(0, 5 ether, 2 days, 1000, 1);
        handler.create(0, 5 ether, 2 days, 1000, 0);
        assertEq(handler.idCount(), 0);
        handler.setPaused(false);
        handler.setTokenAllowed(false, 1); // token two
        handler.create(0, 5 ether, 2 days, 1000, 2);
        assertEq(handler.idCount(), 0);
        handler.create(0, 5 ether, 2 days, 1000, 0); // token one is still allowed
        assertEq(handler.idCount(), 1);
        assertFalse(handler.accessBroken());
    }

    /// The wrong-currency probe really tries something that is rejected (and the handler detects success).
    function test_WrongCurrencyProbeIsRejected() public {
        handler.create(0, 5 ether, 2 days, 1000, 1); // ETH campaign
        handler.create(0, 5 ether, 2 days, 1000, 0); // token campaign
        handler.attackCurrency(1, 0, 1 ether);
        handler.attackCurrency(1, 1, 1 ether);
        assertFalse(handler.accessBroken());
    }
}
