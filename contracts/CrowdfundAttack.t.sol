// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";

contract Forcer {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// Hostile actor usable as creator and backer. On receive it runs a configurable action.
contract Hostile {
    Crowdfund public cf;
    uint256 public mode;
    uint256 public a; // campaign id args
    uint256 public b;
    uint256 public hits;
    bool public lastOk;
    bytes public lastErr;

    constructor(Crowdfund _cf) {
        cf = _cf;
    }

    function setMode(uint256 m, uint256 _a, uint256 _b) external {
        mode = m;
        a = _a;
        b = _b;
    }

    function create(uint256 goal, uint256 dl) external returns (uint256) {
        return cf.createCampaign(goal, dl, 1000);
    }

    function pledge(uint256 id) external payable {
        cf.pledge{value: msg.value}(id);
    }

    function doWithdraw(uint256 id) external {
        cf.withdraw(id);
    }

    function doRefund(uint256 id) external {
        cf.refund(id);
    }

    function doWithdrawGas(uint256 id, uint256 gasLimit) external returns (bool ok) {
        (ok,) = address(cf).call{gas: gasLimit}(abi.encodeCall(Crowdfund.withdraw, (id)));
    }

    receive() external payable {
        hits++;
        if (mode == 1) {
            // cross-campaign reentrancy: withdraw other campaign
            try cf.withdraw(a) {
                lastOk = true;
            } catch (bytes memory e) {
                lastOk = false;
                lastErr = e;
            }
        } else if (mode == 2) {
            try cf.refund(a) {
                lastOk = true;
            } catch (bytes memory e) {
                lastOk = false;
                lastErr = e;
            }
        } else if (mode == 3) {
            // pledge into same campaign (ended) / other campaign (active) using received ETH
            try cf.pledge{value: msg.value}(a) {
                lastOk = true;
            } catch (bytes memory e) {
                lastOk = false;
                lastErr = e;
            }
        } else if (mode == 4) {
            // burn all gas
            while (true) {}
        } else if (mode == 5) {
            // return bomb
            assembly {
                return(0, 0x2000000)
            }
        } else if (mode == 6) {
            revert("no");
        } else if (mode == 7) {
            // create a new campaign mid-callback (should not matter)
            try cf.createCampaign(1, block.timestamp + 2 days, 1000) returns (uint256) {
                lastOk = true;
            } catch {
                lastOk = false;
            }
        }
    }
}

contract AttackTest is Test {
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

    function _create(address who, uint256 goal) internal returns (uint256 id) {
        vm.prank(who);
        id = cf.createCampaign(goal, deadline, 1000);
    }

    function _pledge(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        cf.pledge{value: amount}(id);
    }

    // 1. cross-campaign reentrancy on withdraw: creator of A and B tries to withdraw B inside A's payout
    function test_Attack_CrossCampaignWithdrawReentry() public {
        Hostile h = new Hostile(cf);
        vm.prank(address(h));
        uint256 a = cf.createCampaign(GOAL, deadline, 1000);
        vm.prank(address(h));
        uint256 b = cf.createCampaign(GOAL, deadline, 1000);
        _pledge(alice, a, GOAL);
        _pledge(alice, b, GOAL);
        vm.warp(deadline);
        h.setMode(1, b, 0);
        h.doWithdraw(a);
        assertFalse(h.lastOk(), "nested withdraw must fail");
        assertEq(address(h).balance, GOAL, "only A paid");
        assertEq(address(cf).balance, GOAL, "B funds intact");
        h.setMode(0, 0, 0);
        h.doWithdraw(b);
        assertEq(address(cf).balance, 0);
    }

    // 2. refund callback tries to refund other campaign and withdraw
    function test_Attack_RefundCallbackCrossRefund() public {
        uint256 a = _create(creator, GOAL);
        uint256 b = _create(creator, GOAL);
        Hostile h = new Hostile(cf);
        vm.deal(address(h), 2 ether);
        h.pledge{value: 1 ether}(a);
        h.pledge{value: 1 ether}(b);
        vm.warp(deadline);
        h.setMode(2, b, 0);
        h.doRefund(a);
        assertFalse(h.lastOk(), "nested refund must fail");
        assertEq(address(h).balance, 3 ether);
        assertEq(cf.pledgeOf(b, address(h)), 1 ether);
        assertEq(address(cf).balance, 1 ether);
    }

    // 3. refund callback re-pledges the refunded ETH into the same (ended) campaign: must fail
    function test_Attack_RefundCallbackRepledgeSame() public {
        uint256 a = _create(creator, GOAL);
        Hostile h = new Hostile(cf);
        vm.deal(address(h), 1 ether);
        h.pledge{value: 1 ether}(a);
        vm.warp(deadline);
        h.setMode(3, a, 0);
        h.doRefund(a);
        assertFalse(h.lastOk());
        assertEq(cf.pledgeOf(a, address(h)), 0);
        assertEq(address(h).balance, 2 ether);
    }

    // 4. refund callback re-pledges into a different active campaign: legit, accounting must stay sound
    function test_Attack_RefundCallbackPledgeOtherActive() public {
        uint256 a = _create(creator, GOAL);
        // campaign C created later with a longer deadline
        vm.prank(creator);
        uint256 c = cf.createCampaign(GOAL, deadline + 30 days, 1000);
        Hostile h = new Hostile(cf);
        vm.deal(address(h), 1 ether);
        h.pledge{value: 1 ether}(a);
        vm.warp(deadline);
        h.setMode(3, c, 0);
        h.doRefund(a);
        assertTrue(h.lastOk());
        assertEq(cf.pledgeOf(c, address(h)), 1 ether);
        assertEq(address(cf).balance, 1 ether);
        assertEq(cf.getCampaign(a).refunded, 1 ether);
    }

    // 5. creator callback pledges payout into its own (ended) campaign: must fail
    function test_Attack_WithdrawCallbackPledgeBack() public {
        Hostile h = new Hostile(cf);
        vm.prank(address(h));
        uint256 a = cf.createCampaign(GOAL, deadline, 1000);
        _pledge(alice, a, GOAL);
        vm.warp(deadline);
        h.setMode(3, a, 0);
        h.doWithdraw(a);
        assertFalse(h.lastOk());
        assertEq(address(cf).balance, 0);
    }

    // 6. withdraw twice
    function test_Attack_DoubleWithdraw() public {
        uint256 a = _create(creator, GOAL);
        _pledge(alice, a, GOAL);
        vm.warp(deadline);
        vm.startPrank(creator);
        cf.withdraw(a);
        vm.expectRevert(Crowdfund.AlreadyPaid.selector);
        cf.withdraw(a);
        vm.stopPrank();
    }

    // 7. refund after success and withdraw after failure
    function test_Attack_WrongOutcome() public {
        uint256 a = _create(creator, GOAL);
        uint256 b = _create(creator, GOAL);
        _pledge(alice, a, GOAL);
        _pledge(alice, b, GOAL - 1);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(a);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.GoalNotReached.selector);
        cf.withdraw(b);
    }

    // 8. exact goal boundary and 1 wei short
    function test_Attack_GoalBoundary() public {
        uint256 a = _create(creator, GOAL);
        _pledge(alice, a, GOAL - 1);
        _pledge(bob, a, 1);
        vm.warp(deadline);
        assertEq(uint256(cf.statusOf(a)), uint256(Crowdfund.Status.Succeeded));
        vm.prank(creator);
        cf.withdraw(a);
        assertEq(creator.balance, GOAL);
    }

    // 9. deadline boundary: deadline-1 pledge ok, deadline pledge rejected, withdraw at deadline-1 rejected
    function test_Attack_DeadlineBoundary() public {
        uint256 a = _create(creator, GOAL);
        vm.warp(deadline - 1);
        _pledge(alice, a, GOAL);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.withdraw(a);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.refund(a);
        vm.warp(deadline);
        vm.prank(bob);
        vm.expectRevert(Crowdfund.CampaignEnded.selector);
        cf.pledge{value: 1}(a);
        vm.prank(creator);
        cf.withdraw(a);
    }

    // 10. forced ETH via selfdestruct does not break payouts or refunds
    function test_Attack_ForcedEth() public {
        uint256 a = _create(creator, GOAL);
        uint256 b = _create(creator, GOAL);
        _pledge(alice, a, GOAL);
        _pledge(bob, b, 1 ether);
        new Forcer{value: 5 ether}(payable(address(cf)));
        assertEq(address(cf).balance, GOAL + 1 ether + 5 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(a);
        vm.prank(bob);
        cf.refund(b);
        assertEq(creator.balance, GOAL);
        assertEq(bob.balance, 100 ether);
        assertEq(address(cf).balance, 5 ether); // stuck, known limit
    }

    // 11. plain ETH send reverts
    function test_Attack_PlainSendReverts() public {
        (bool ok,) = address(cf).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(cf).call{value: 1}(hex"deadbeef");
        assertFalse(ok);
    }

    // 12. id 0 / huge ids
    function test_Attack_BadIds() public {
        _create(creator, GOAL);
        uint256[3] memory ids = [uint256(0), 2, type(uint256).max];
        for (uint256 i; i < 3; i++) {
            vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
            cf.getCampaign(ids[i]);
            vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
            cf.statusOf(ids[i]);
            vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
            cf.pledge{value: 1}(ids[i]);
            vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
            cf.withdraw(ids[i]);
            vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
            cf.refund(ids[i]);
            assertEq(cf.pledgeOf(ids[i], alice), 0);
        }
    }

    // 13. pledge with msg.value 0, and revert order for nonexistent + zero
    function test_Attack_ZeroValue() public {
        uint256 a = _create(creator, GOAL);
        vm.expectRevert(Crowdfund.ZeroAmount.selector);
        cf.pledge(a);
    }

    // 14. creator griefing: a rejecting creator cannot block backers of another campaign or its own... failed campaign refunds
    function test_Attack_RejectingCreatorDoesNotBlockOthers() public {
        Hostile h = new Hostile(cf);
        vm.prank(address(h));
        uint256 a = cf.createCampaign(GOAL, deadline, 1000);
        uint256 b = _create(creator, GOAL);
        _pledge(alice, a, GOAL);
        _pledge(bob, b, 1 ether);
        vm.warp(deadline);
        h.setMode(6, 0, 0);
        vm.expectRevert(Crowdfund.TransferFailed.selector);
        h.doWithdraw(a);
        // other campaign refund still works
        vm.prank(bob);
        cf.refund(b);
        // A state unchanged, funds still held
        assertFalse(cf.getCampaign(a).paidOut);
        assertEq(address(cf).balance, GOAL);
        // creator can retry later once it accepts ETH
        h.setMode(0, 0, 0);
        h.doWithdraw(a);
        assertEq(address(h).balance, GOAL);
    }

    // 15. gas burner creator: withdraw with all gas burned fails cleanly, no state change; others unaffected
    function test_Attack_GasBurnerCreator() public {
        Hostile h = new Hostile(cf);
        vm.prank(address(h));
        uint256 a = cf.createCampaign(GOAL, deadline, 1000);
        _pledge(alice, a, GOAL);
        vm.warp(deadline);
        h.setMode(4, 0, 0);
        bool ok = h.doWithdrawGas(a, 2_000_000);
        assertFalse(ok);
        assertFalse(cf.getCampaign(a).paidOut);
        assertEq(address(cf).balance, GOAL);
    }

    // 16. return bomb from a backer cannot DoS/hurt others; refund of the bomber itself
    function test_Attack_ReturnBombBacker() public {
        uint256 a = _create(creator, GOAL);
        Hostile h = new Hostile(cf);
        vm.deal(address(h), 1 ether);
        h.pledge{value: 1 ether}(a);
        _pledge(alice, a, 1 ether);
        vm.warp(deadline);
        h.setMode(5, 0, 0);
        uint256 g = gasleft();
        try h.doRefund(a) {} catch {}
        emit log_named_uint("gas used by return-bomb refund attempt", g - gasleft());
        // alice unaffected
        vm.prank(alice);
        cf.refund(a);
        assertEq(alice.balance, 100 ether);
    }

    // 17. withdraw callback creates a new campaign / pledges etc: no corruption
    function test_Attack_WithdrawCallbackCreate() public {
        Hostile h = new Hostile(cf);
        vm.prank(address(h));
        uint256 a = cf.createCampaign(GOAL, deadline, 1000);
        _pledge(alice, a, GOAL);
        vm.warp(deadline);
        h.setMode(7, 0, 0);
        h.doWithdraw(a);
        assertTrue(h.lastOk());
        assertEq(cf.campaignCount(), 2);
    }

    // 18. creator wash-pledge to top up goal at last second and withdraw: creator only loses own money
    function test_Attack_CreatorTopUpSnipe() public {
        uint256 a = _create(creator, GOAL);
        _pledge(alice, a, 9 ether);
        vm.deal(creator, 1 ether);
        vm.warp(deadline - 1);
        _pledge(creator, a, 1 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(a);
        // creator net: +10 -1 = +9 of backer funds. Alice cannot refund.
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(a);
        assertEq(creator.balance, 10 ether);
    }

    // 19. createCampaign bounds, uint64 cast, overflow
    function test_Attack_CreateBounds() public {
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, type(uint256).max, 1000);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, uint256(type(uint64).max) + 1 + block.timestamp, 1000);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, 0, 1000);
        cf.createCampaign(1, block.timestamp + 1 days, 1000);
        cf.createCampaign(1, block.timestamp + 90 days, 1000);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, block.timestamp + 1 days - 1, 1000);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, block.timestamp + 90 days + 1, 1000);
        // far-future timestamp near the uint64 limit: a deadline that would not fit is rejected
        // instead of being silently truncated (fixed after the attack review of stage 1)
        vm.warp(type(uint64).max - 1 days);
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, block.timestamp + 90 days, 1000);
    }

    // 20. goal = max uint, raised can never reach; refunds always work
    function test_Attack_HugeGoal() public {
        uint256 a;
        vm.prank(creator);
        a = cf.createCampaign(type(uint256).max, deadline, 1000);
        _pledge(alice, a, 50 ether);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(a);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.GoalNotReached.selector);
        cf.withdraw(a);
    }

    // 21. someone else's pledge cannot be refunded by a third party; refund twice
    function test_Attack_RefundTheft() public {
        uint256 a = _create(creator, GOAL);
        _pledge(alice, a, 1 ether);
        vm.warp(deadline);
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(a);
        vm.startPrank(alice);
        cf.refund(a);
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(a);
        vm.stopPrank();
        assertEq(address(cf).balance, 0);
    }

    // 22. non-creator withdraw
    function test_Attack_NonCreatorWithdraw() public {
        uint256 a = _create(creator, GOAL);
        _pledge(alice, a, GOAL);
        vm.warp(deadline);
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NotCreator.selector);
        cf.withdraw(a);
    }

    // 23. zero-raised failed campaign: statusOf Failed, refund reverts NothingToRefund, no division etc.
    function test_Attack_EmptyCampaign() public {
        uint256 a = _create(creator, GOAL);
        vm.warp(deadline);
        assertEq(uint256(cf.statusOf(a)), uint256(Crowdfund.Status.Failed));
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(a);
    }

    // 24. fuzz: many campaigns, many backers, random outcomes; contract balance never below owed, never overpays
    function testFuzz_Attack_Solvency(uint96[6] memory amts, uint96[3] memory goals) public {
        uint256[3] memory ids;
        for (uint256 i; i < 3; i++) {
            vm.prank(creator);
            ids[i] = cf.createCampaign(uint256(goals[i]) + 1, deadline, 1000);
        }
        address[2] memory bs = [alice, bob];
        uint256 totalIn;
        for (uint256 i; i < 6; i++) {
            uint256 amt = uint256(amts[i]) % 50 ether + 1;
            vm.deal(bs[i % 2], amt);
            _pledge(bs[i % 2], ids[i % 3], amt);
            totalIn += amt;
        }
        vm.warp(deadline);
        uint256 balBefore = address(cf).balance;
        assertEq(balBefore, totalIn);
        for (uint256 i; i < 3; i++) {
            Crowdfund.Campaign memory c = cf.getCampaign(ids[i]);
            if (c.raised >= c.goal) {
                vm.prank(creator);
                cf.withdraw(ids[i]);
            } else {
                for (uint256 j; j < 2; j++) {
                    if (cf.pledgeOf(ids[i], bs[j]) > 0) {
                        vm.prank(bs[j]);
                        cf.refund(ids[i]);
                    }
                }
                assertEq(cf.getCampaign(ids[i]).refunded, cf.getCampaign(ids[i]).raised);
            }
        }
        assertEq(address(cf).balance, 0, "everything paid out exactly once");
    }
}
