// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

function firstSelector(bytes memory data) pure returns (bytes4 sel) {
    if (data.length >= 4) {
        assembly {
            sel := mload(add(data, 32))
        }
    }
}

/// Creator contract that tries to re-enter withdraw() and refund() when it receives ETH,
/// and records exactly which error each inner call failed with.
contract ReentrantCreator {
    Crowdfund public cf;
    uint256 public id;
    bool public swallow;
    uint256 public hits;
    bytes4 public lastWithdrawError;
    bytes4 public lastRefundError;

    constructor(Crowdfund _cf, bool _swallow) {
        cf = _cf;
        swallow = _swallow;
    }

    function create(uint256 goal, uint256 dl) external {
        id = cf.createCampaign(goal, dl, 1000);
    }

    function attack() external {
        cf.withdraw(id);
    }

    receive() external payable {
        hits++;
        if (swallow) {
            try cf.withdraw(id) {} catch (bytes memory d) {
                lastWithdrawError = firstSelector(d);
            }
            try cf.refund(id) {} catch (bytes memory d) {
                lastRefundError = firstSelector(d);
            }
        } else {
            cf.withdraw(id);
        }
    }
}

/// Backer contract that tries to re-enter refund() / withdraw() when it receives ETH,
/// and records exactly which error each inner call failed with.
contract ReentrantBacker {
    Crowdfund public cf;
    uint256 public id;
    bool public swallow;
    uint256 public hits;
    bytes4 public lastRefundError;
    bytes4 public lastWithdrawError;

    constructor(Crowdfund _cf, bool _swallow) {
        cf = _cf;
        swallow = _swallow;
    }

    function pledge(uint256 _id) external payable {
        id = _id;
        cf.pledge{value: msg.value}(_id);
    }

    function attack() external {
        cf.refund(id);
    }

    receive() external payable {
        hits++;
        if (swallow) {
            try cf.refund(id) {} catch (bytes memory d) {
                lastRefundError = firstSelector(d);
            }
            try cf.withdraw(id) {} catch (bytes memory d) {
                lastWithdrawError = firstSelector(d);
            }
        } else {
            cf.refund(id);
        }
    }
}

/// Creator contract that cannot receive ETH.
contract RejectingCreator {
    function create(Crowdfund cf, uint256 goal, uint256 dl) external returns (uint256) {
        return cf.createCampaign(goal, dl, 1000);
    }

    function withdraw(Crowdfund cf, uint256 id) external {
        cf.withdraw(id);
    }
}

contract CrowdfundTest is Test {
    Crowdfund cf;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant GOAL = 10 ether;
    uint256 deadline;

    function setUp() public {
        cf = new Crowdfund(address(this), makeAddr("feeRecipient"), 0);
        vm.warp(1_000_000);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(mallory, 100 ether);
        deadline = block.timestamp + 7 days;
    }

    function _create() internal returns (uint256 id) {
        vm.prank(creator);
        id = cf.createCampaign(GOAL, deadline, 1000);
    }

    function _pledge(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        cf.pledge{value: amount}(id);
    }

    // ---------------------------------------------------------------- createCampaign

    function test_Create_StoresCampaignAndEmits() public {
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.CampaignCreated(1, creator, GOAL, uint64(deadline), 0, address(0));
        uint256 id = _create();

        assertEq(id, 1);
        assertEq(cf.campaignCount(), 1);
        Crowdfund.Campaign memory c = cf.getCampaign(id);
        assertEq(c.creator, creator);
        assertEq(c.goal, GOAL);
        assertEq(c.deadline, uint64(deadline));
        assertEq(c.raised, 0);
        assertEq(c.refunded, 0);
        assertFalse(c.paidOut);
        assertEq(uint256(cf.statusOf(id)), uint256(Crowdfund.Status.Active));
    }

    function test_Create_IdsIncrease() public {
        uint256 a = _create();
        uint256 b = _create();
        assertEq(a, 1);
        assertEq(b, 2);
    }

    function test_Create_RevertsOnZeroGoal() public {
        vm.expectRevert(Crowdfund.ZeroGoal.selector);
        cf.createCampaign(0, deadline, 1000);
    }

    function test_Create_DeadlineBoundsAreInclusive() public {
        uint256 t = block.timestamp;
        cf.createCampaign(1, t + 1 days, 1000);
        cf.createCampaign(1, t + 90 days, 1000);

        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, t + 1 days - 1, 1000);

        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, t + 90 days + 1, 1000);
    }

    function test_Create_RevertsOnPastOrZeroDeadline() public {
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, 0, 1000);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, block.timestamp - 1, 1000);
    }

    function test_Create_RevertsOnHugeDeadline() public {
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, type(uint256).max, 1000);
    }

    // ---------------------------------------------------------------- pledge

    function test_Pledge_AccumulatesAndEmits() public {
        uint256 id = _create();

        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Pledged(id, alice, 3 ether);
        _pledge(alice, id, 3 ether);
        _pledge(alice, id, 2 ether);
        _pledge(bob, id, 1 ether);

        assertEq(cf.pledgeOf(id, alice), 5 ether);
        assertEq(cf.pledgeOf(id, bob), 1 ether);
        assertEq(cf.getCampaign(id).raised, 6 ether);
        assertEq(address(cf).balance, 6 ether);
    }

    function test_Pledge_RevertsOnUnknownCampaign() public {
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledge{value: 1 ether}(0);

        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledge{value: 1 ether}(99);
    }

    function test_Pledge_RevertsOnZeroValue() public {
        uint256 id = _create();
        vm.prank(alice);
        vm.expectRevert(Crowdfund.ZeroAmount.selector);
        cf.pledge{value: 0}(id);
    }

    function test_Pledge_ClosesExactlyAtDeadline() public {
        uint256 id = _create();

        vm.warp(deadline - 1);
        _pledge(alice, id, 1 ether); // last second is still open

        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.CampaignEnded.selector);
        cf.pledge{value: 1 ether}(id);

        vm.warp(deadline + 365 days);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.CampaignEnded.selector);
        cf.pledge{value: 1 ether}(id);
    }

    function test_Pledge_CreatorMayPledgeToOwnCampaign() public {
        uint256 id = _create();
        vm.deal(creator, 5 ether);
        _pledge(creator, id, 5 ether);
        assertEq(cf.pledgeOf(id, creator), 5 ether);
    }

    function test_Pledge_OverfundingAllowed() public {
        uint256 id = _create();
        _pledge(alice, id, 25 ether);
        assertEq(cf.getCampaign(id).raised, 25 ether);
    }

    function test_PlainEthTransferReverts() public {
        (bool ok,) = address(cf).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(cf).balance, 0);
    }

    // ---------------------------------------------------------------- withdraw

    function test_Withdraw_PaysCreatorAfterSuccess() public {
        uint256 id = _create();
        _pledge(alice, id, 6 ether);
        _pledge(bob, id, 6 ether);
        vm.warp(deadline);

        assertEq(uint256(cf.statusOf(id)), uint256(Crowdfund.Status.Succeeded));

        uint256 before = creator.balance;
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Withdrawn(id, creator, 12 ether, 0);
        vm.prank(creator);
        cf.withdraw(id);

        assertEq(creator.balance - before, 12 ether);
        assertEq(address(cf).balance, 0);
        assertTrue(cf.getCampaign(id).paidOut);
        assertEq(uint256(cf.statusOf(id)), uint256(Crowdfund.Status.Paid));
    }

    function test_Withdraw_ExactGoalSucceeds() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(creator.balance, GOAL);
    }

    function test_Withdraw_OneWeiShortFails() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL - 1);
        vm.warp(deadline);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.GoalNotReached.selector);
        cf.withdraw(id);
        assertEq(uint256(cf.statusOf(id)), uint256(Crowdfund.Status.Failed));
    }

    function test_Withdraw_RevertsBeforeDeadlineEvenIfGoalReached() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline - 1);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.withdraw(id);
    }

    function test_Withdraw_OnlyCreator() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);

        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NotCreator.selector);
        cf.withdraw(id);

        vm.prank(alice); // even a backer cannot
        vm.expectRevert(Crowdfund.NotCreator.selector);
        cf.withdraw(id);
    }

    function test_Withdraw_OnlyOnce() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.startPrank(creator);
        cf.withdraw(id);
        vm.expectRevert(Crowdfund.AlreadyPaid.selector);
        cf.withdraw(id);
        vm.stopPrank();
    }

    function test_Withdraw_UnknownCampaign() public {
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.withdraw(1);
    }

    function test_Withdraw_RejectingCreatorLocksOnlyItsOwnFunds() public {
        RejectingCreator rc = new RejectingCreator();
        uint256 id = rc.create(cf, GOAL, deadline);
        _pledge(alice, id, GOAL);
        uint256 other = _create();
        _pledge(bob, other, 3 ether);
        vm.warp(deadline);

        vm.expectRevert(Crowdfund.TransferFailed.selector);
        rc.withdraw(cf, id);

        assertFalse(cf.getCampaign(id).paidOut);
        assertEq(address(cf).balance, GOAL + 3 ether);
    }

    function test_Withdraw_ReentrancyThatBubblesReverts() public {
        ReentrantCreator rc = new ReentrantCreator(cf, false);
        rc.create(GOAL, deadline);
        _pledge(alice, rc.id(), GOAL);
        vm.warp(deadline);

        vm.expectRevert(Crowdfund.TransferFailed.selector);
        rc.attack();

        assertFalse(cf.getCampaign(rc.id()).paidOut);
        assertEq(address(cf).balance, GOAL);
    }

    function test_Withdraw_ReentrancyThatIsSwallowedPaysOnce() public {
        ReentrantCreator rc = new ReentrantCreator(cf, true);
        rc.create(GOAL, deadline);
        uint256 id = rc.id();
        _pledge(alice, id, GOAL);
        // a second, unrelated campaign holds funds that must not be reachable
        uint256 other = _create();
        _pledge(bob, other, 4 ether);
        vm.warp(deadline);

        rc.attack();

        assertEq(address(rc).balance, GOAL);
        assertEq(address(cf).balance, 4 ether);
        assertEq(rc.hits(), 1);
        assertTrue(cf.getCampaign(id).paidOut);
        // The inner calls must be stopped by the reentrancy guard itself, not by some later check.
        // (Without nonReentrant these would fail with AlreadyPaid / GoalReached instead.)
        assertEq(rc.lastWithdrawError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(rc.lastRefundError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    // ---------------------------------------------------------------- refund

    function test_Refund_ReturnsExactPledgeAfterFailure() public {
        uint256 id = _create();
        _pledge(alice, id, 3 ether);
        _pledge(alice, id, 1 ether);
        _pledge(bob, id, 2 ether);
        vm.warp(deadline);

        assertEq(uint256(cf.statusOf(id)), uint256(Crowdfund.Status.Failed));

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Refunded(id, alice, 4 ether);
        vm.prank(alice);
        cf.refund(id);
        assertEq(alice.balance - aliceBefore, 4 ether);
        assertEq(cf.pledgeOf(id, alice), 0);
        assertEq(cf.getCampaign(id).refunded, 4 ether);
        assertEq(address(cf).balance, 2 ether);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        cf.refund(id);
        assertEq(bob.balance - bobBefore, 2 ether);
        assertEq(address(cf).balance, 0);
        assertEq(cf.getCampaign(id).refunded, 6 ether);
    }

    function test_Refund_OnlyOnce() public {
        uint256 id = _create();
        _pledge(alice, id, 1 ether);
        vm.warp(deadline);
        vm.startPrank(alice);
        cf.refund(id);
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(id);
        vm.stopPrank();
    }

    function test_Refund_NothingForNonBacker() public {
        uint256 id = _create();
        _pledge(alice, id, 1 ether);
        vm.warp(deadline);
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(id);
    }

    function test_Refund_RevertsBeforeDeadline() public {
        uint256 id = _create();
        _pledge(alice, id, 1 ether);
        vm.warp(deadline - 1);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.refund(id);
    }

    function test_Refund_RevertsAfterSuccess() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(id);
    }

    function test_Refund_UnknownCampaign() public {
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.refund(1);
    }

    function test_Refund_CannotBeTriggeredForAnotherBacker() public {
        uint256 id = _create();
        _pledge(alice, id, 1 ether);
        vm.warp(deadline);
        uint256 before = alice.balance;
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(id);
        assertEq(alice.balance, before);
        assertEq(cf.pledgeOf(id, alice), 1 ether);
    }

    function test_Refund_ReentrancyThatBubblesReverts() public {
        uint256 id = _create();
        ReentrantBacker rb = new ReentrantBacker(cf, false);
        rb.pledge{value: 2 ether}(id);
        _pledge(alice, id, 3 ether);
        vm.warp(deadline);

        vm.expectRevert(Crowdfund.TransferFailed.selector);
        rb.attack();

        assertEq(cf.pledgeOf(id, address(rb)), 2 ether);
        assertEq(address(cf).balance, 5 ether);
    }

    function test_Refund_ReentrancyThatIsSwallowedPaysOnce() public {
        uint256 id = _create();
        ReentrantBacker rb = new ReentrantBacker(cf, true);
        rb.pledge{value: 2 ether}(id);
        _pledge(alice, id, 3 ether);
        vm.warp(deadline);

        rb.attack();

        assertEq(address(rb).balance, 2 ether);
        assertEq(rb.hits(), 1);
        assertEq(address(cf).balance, 3 ether); // alice's pledge untouched
        assertEq(cf.pledgeOf(id, alice), 3 ether);
        // Both inner calls must be stopped by the reentrancy guard itself.
        assertEq(rb.lastRefundError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(rb.lastWithdrawError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    // ---------------------------------------------------------------- isolation and views

    function test_Campaigns_AreIsolated() public {
        uint256 a = _create();
        vm.prank(bob);
        uint256 b = cf.createCampaign(5 ether, deadline + 1 days, 1000);

        _pledge(alice, a, 10 ether); // a succeeds
        _pledge(alice, b, 1 ether); // b fails
        vm.warp(deadline + 1 days);

        vm.prank(creator);
        cf.withdraw(a);
        vm.prank(alice);
        cf.refund(b);

        assertEq(creator.balance, 10 ether);
        assertEq(address(cf).balance, 0);
        // alice cannot refund from the successful campaign
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(a);
    }

    function test_Views_RevertOnUnknownCampaign() public {
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.getCampaign(0);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.statusOf(1);
        assertEq(cf.pledgeOf(1, alice), 0);
    }

    // ---------------------------------------------------------------- revert ordering
    // Each test violates an earlier check AND a later check, and asserts the earlier error,
    // so swapping two checks in the contract makes a test fail.

    function test_Order_Create_ZeroGoalBeforeBadDeadline() public {
        vm.expectRevert(Crowdfund.ZeroGoal.selector);
        cf.createCampaign(0, 0, 1000);
    }

    function test_Order_Pledge_UnknownIdBeforeZeroValue() public {
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledge{value: 0}(42);
    }

    function test_Order_Pledge_ZeroValueBeforeEnded() public {
        uint256 id = _create();
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.ZeroAmount.selector);
        cf.pledge{value: 0}(id);
    }

    function test_Order_Withdraw_UnknownIdBeforeNotCreator() public {
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.withdraw(42);
    }

    function test_Order_Withdraw_NotCreatorBeforeNotEnded() public {
        uint256 id = _create(); // still active, goal not reached
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NotCreator.selector);
        cf.withdraw(id);
    }

    function test_Order_Withdraw_NotEndedBeforeGoalNotReached() public {
        uint256 id = _create(); // still active, goal not reached
        vm.prank(creator);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.withdraw(id);
    }

    function test_Order_Withdraw_GoalNotReachedBeforeAlreadyPaid() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL - 1);
        vm.warp(deadline);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.GoalNotReached.selector);
        cf.withdraw(id);
    }

    function test_Order_Refund_UnknownIdBeforeNotEnded() public {
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.refund(42);
    }

    function test_Order_Refund_NotEndedBeforeGoalReached() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL); // goal reached but still active
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.refund(id);
    }

    function test_Order_Refund_NotEndedBeforeNothingToRefund() public {
        uint256 id = _create();
        vm.prank(mallory); // not a backer, still active
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.refund(id);
    }

    function test_Order_Refund_GoalReachedBeforeNothingToRefund() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(mallory); // not a backer, goal reached
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(id);
    }

    // ---------------------------------------------------------------- forced ETH

    /// ETH pushed into the contract without going through pledge() must not change what is paid.
    function test_ForcedEth_DoesNotChangePayoutOrRefunds() public {
        uint256 ok = _create();
        vm.prank(bob);
        uint256 bad = cf.createCampaign(50 ether, deadline, 1000);
        _pledge(alice, ok, GOAL);
        _pledge(alice, bad, 2 ether);
        vm.warp(deadline);

        vm.deal(address(cf), address(cf).balance + 7 ether); // simulate a forced send

        vm.prank(creator);
        cf.withdraw(ok);
        assertEq(creator.balance, GOAL); // exactly raised, not raised plus the extra

        uint256 before = alice.balance;
        vm.prank(alice);
        cf.refund(bad);
        assertEq(alice.balance - before, 2 ether);

        assertEq(address(cf).balance, 7 ether); // the forced ETH stays, untouched
    }

    // ---------------------------------------------------------------- limits

    function test_Create_RevertsIfDeadlineWouldNotFitUint64() public {
        vm.warp(uint256(type(uint64).max) - 1 days);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, block.timestamp + 90 days, 1000);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_Create_DeadlineBounds(uint256 offset) public {
        offset = bound(offset, 0, 200 days);
        bool valid = offset >= 1 days && offset <= 90 days;
        if (valid) {
            cf.createCampaign(1, block.timestamp + offset, 1000);
        } else {
            vm.expectRevert(Crowdfund.InvalidDeadline.selector);
            cf.createCampaign(1, block.timestamp + offset, 1000);
        }
    }

    function testFuzz_OutcomeMatchesGoal(uint256 goal, uint256 a, uint256 b) public {
        goal = bound(goal, 1, 1000 ether);
        a = bound(a, 1, 600 ether);
        b = bound(b, 1, 600 ether);

        vm.prank(creator);
        uint256 id = cf.createCampaign(goal, deadline, 1000);
        vm.deal(alice, a);
        vm.deal(bob, b);
        _pledge(alice, id, a);
        _pledge(bob, id, b);
        vm.warp(deadline);

        if (a + b >= goal) {
            vm.prank(alice);
            vm.expectRevert(Crowdfund.GoalReached.selector);
            cf.refund(id);

            vm.prank(creator);
            cf.withdraw(id);
            assertEq(creator.balance, a + b);
            assertEq(address(cf).balance, 0);
        } else {
            vm.prank(creator);
            vm.expectRevert(Crowdfund.GoalNotReached.selector);
            cf.withdraw(id);

            uint256 aBefore = alice.balance;
            uint256 bBefore = bob.balance;
            vm.prank(alice);
            cf.refund(id);
            vm.prank(bob);
            cf.refund(id);
            assertEq(alice.balance - aBefore, a);
            assertEq(bob.balance - bBefore, b);
            assertEq(address(cf).balance, 0);
        }
    }

    function testFuzz_PledgeThenRefundNeverExceedsPledge(uint256 amount, uint256 extra) public {
        amount = bound(amount, 1, 50 ether);
        extra = bound(extra, 0, 50 ether);
        uint256 id = _create();
        _pledge(alice, id, amount);
        if (extra > 0) _pledge(bob, id, extra);
        vm.warp(deadline);

        // GOAL is 10 ether, so only a campaign below it can refund
        if (amount + extra >= GOAL) return;
        uint256 before = alice.balance;
        vm.prank(alice);
        cf.refund(id);
        assertEq(alice.balance - before, amount);
        assertEq(address(cf).balance, extra);
    }
}
