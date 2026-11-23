// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Fee recipient that tries to re-enter the contract when it receives its fees.
contract ReentrantRecipient {
    Crowdfund public cf;
    uint256 public id;
    uint256 public hits;
    bytes4 public lastClaimError;
    bytes4 public lastWithdrawError;
    bytes4 public lastRefundError;

    constructor(Crowdfund _cf) {
        cf = _cf;
    }

    function setId(uint256 _id) external {
        id = _id;
    }

    receive() external payable {
        hits++;
        try cf.claimFees() {} catch (bytes memory d) {
            lastClaimError = _sel(d);
        }
        try cf.withdraw(id) {} catch (bytes memory d) {
            lastWithdrawError = _sel(d);
        }
        try cf.refund(id) {} catch (bytes memory d) {
            lastRefundError = _sel(d);
        }
    }

    function _sel(bytes memory d) internal pure returns (bytes4 s) {
        if (d.length >= 4) {
            assembly {
                s := mload(add(d, 32))
            }
        }
    }
}

/// Fee recipient that cannot receive ETH.
contract RejectingRecipient {}

contract CrowdfundFeeTest is Test {
    Crowdfund cf;

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant GOAL = 10 ether;
    uint256 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800); // 8%
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
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

    function _fundAndEnd(uint256 id, uint256 amount) internal {
        _pledge(alice, id, amount);
        vm.warp(deadline);
    }

    // ---------------------------------------------------------------- constructor

    function test_Constructor_SetsState() public view {
        assertEq(cf.owner(), owner);
        assertEq(cf.feeRecipient(), recipient);
        assertEq(cf.feeBps(), 800);
        assertFalse(cf.creationPaused());
        assertEq(cf.accruedFees(), 0);
        assertEq(cf.MAX_FEE_BPS(), 1000);
        assertEq(cf.BPS(), 10_000);
    }

    function test_Constructor_EmitsInitialEvents() public {
        vm.expectEmit(false, false, false, true);
        emit Crowdfund.FeeUpdated(250);
        vm.expectEmit(true, false, false, false);
        emit Crowdfund.FeeRecipientUpdated(recipient);
        new Crowdfund(owner, recipient, 250);
    }

    function test_Constructor_RevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Crowdfund(address(0), recipient, 100);
    }

    function test_Constructor_RevertsOnZeroRecipient() public {
        vm.expectRevert(Crowdfund.ZeroAddress.selector);
        new Crowdfund(owner, address(0), 100);
    }

    function test_Constructor_CapIsInclusive() public {
        new Crowdfund(owner, recipient, 1000);
        vm.expectRevert(Crowdfund.FeeTooHigh.selector);
        new Crowdfund(owner, recipient, 1001);
    }

    // ---------------------------------------------------------------- setFee

    function test_SetFee_OnlyOwner() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.setFee(0);
    }

    function test_SetFee_CapIsInclusiveAndEmits() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(cf));
        emit Crowdfund.FeeUpdated(1000);
        cf.setFee(1000);
        assertEq(cf.feeBps(), 1000);

        vm.expectRevert(Crowdfund.FeeTooHigh.selector);
        cf.setFee(1001);
        vm.expectRevert(Crowdfund.FeeTooHigh.selector);
        cf.setFee(type(uint16).max);
        cf.setFee(0);
        assertEq(cf.feeBps(), 0);
        vm.stopPrank();
    }

    function test_SetFee_AppliesOnlyToNewCampaigns() public {
        uint256 first = _create(); // created at 8%
        vm.prank(owner);
        cf.setFee(1000);
        uint256 second = _create(); // created at 10%
        vm.prank(owner);
        cf.setFee(0);
        uint256 third = _create(); // created at 0%

        assertEq(cf.getCampaign(first).feeBps, 800);
        assertEq(cf.getCampaign(second).feeBps, 1000);
        assertEq(cf.getCampaign(third).feeBps, 0);

        _pledge(alice, first, 100 ether);
        _pledge(alice, second, 100 ether);
        _pledge(alice, third, 100 ether);
        vm.warp(deadline);

        vm.startPrank(creator);
        cf.withdraw(first);
        assertEq(creator.balance, 92 ether);
        cf.withdraw(second);
        assertEq(creator.balance, 92 ether + 90 ether);
        cf.withdraw(third);
        assertEq(creator.balance, 92 ether + 90 ether + 100 ether);
        vm.stopPrank();

        assertEq(cf.accruedFees(), 8 ether + 10 ether);
    }

    function test_CampaignCreatedEventCarriesFee() public {
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.CampaignCreated(1, creator, GOAL, uint64(deadline), 800, address(0));
        _create();
    }

    // ---------------------------------------------------------------- setFeeRecipient

    function test_SetFeeRecipient_OnlyOwnerAndNotZero() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.setFeeRecipient(mallory);

        vm.prank(owner);
        vm.expectRevert(Crowdfund.ZeroAddress.selector);
        cf.setFeeRecipient(address(0));

        vm.expectEmit(true, false, false, false, address(cf));
        emit Crowdfund.FeeRecipientUpdated(bob);
        vm.prank(owner);
        cf.setFeeRecipient(bob);
        assertEq(cf.feeRecipient(), bob);
    }

    // ---------------------------------------------------------------- pause

    function test_Pause_OnlyOwner() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.setCreationPaused(true);
    }

    function test_Pause_BlocksOnlyCreation() public {
        uint256 id = _create();
        _pledge(alice, id, 5 ether);
        vm.prank(owner);
        cf.setCreationPaused(true);
        assertTrue(cf.creationPaused());

        vm.prank(creator);
        vm.expectRevert(Crowdfund.CreationPaused.selector);
        cf.createCampaign(GOAL, deadline, 1000);

        _pledge(bob, id, 6 ether); // pledging still works
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id); // payout still works
        cf.claimFees(); // claiming still works
        assertEq(recipient.balance, 0.88 ether);

        vm.prank(owner);
        cf.setCreationPaused(false);
        vm.prank(creator);
        cf.createCampaign(GOAL, block.timestamp + 7 days, 1000); // creation works again
    }

    function test_Pause_ComesBeforeOtherCreateChecks() public {
        vm.prank(owner);
        cf.setCreationPaused(true);
        vm.expectRevert(Crowdfund.CreationPaused.selector);
        cf.createCampaign(0, 0, 1000); // zero goal and bad deadline too, paused wins
    }

    function test_Pause_DoesNotBlockRefunds() public {
        uint256 id = _create();
        _pledge(alice, id, 1 ether);
        vm.prank(owner);
        cf.setCreationPaused(true);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(id);
        assertEq(address(cf).balance, 0);
    }

    // ---------------------------------------------------------------- withdraw with a fee

    function test_Withdraw_SplitsPayoutAndFee() public {
        uint256 id = _create();
        _pledge(alice, id, 6 ether);
        _pledge(bob, id, 6 ether);
        vm.warp(deadline);

        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Withdrawn(id, creator, 11.04 ether, 0.96 ether);
        vm.prank(creator);
        cf.withdraw(id);

        assertEq(creator.balance, 11.04 ether);
        assertEq(cf.accruedFees(), 0.96 ether);
        assertEq(address(cf).balance, 0.96 ether); // the fee stays in the contract until claimed
        assertEq(recipient.balance, 0);
    }

    function test_Withdraw_FeeRoundsDown() public {
        // 1 wei goal, fee 8%: 8% of 1 wei rounds down to 0
        vm.prank(creator);
        uint256 id = cf.createCampaign(1, deadline, 1000);
        _pledge(alice, id, 1);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(creator.balance, 1);
        assertEq(cf.accruedFees(), 0);

        // 13 wei at 8%: floor(1.04) = 1
        vm.prank(creator);
        uint256 id2 = cf.createCampaign(13, deadline + 1 days, 1000);
        _pledge(alice, id2, 13);
        vm.warp(deadline + 1 days);
        vm.prank(creator);
        cf.withdraw(id2);
        assertEq(cf.accruedFees(), 1);
        assertEq(creator.balance, 1 + 12);
    }

    function test_Withdraw_MaxFee() public {
        vm.prank(owner);
        cf.setFee(1000);
        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(creator.balance, 9 ether);
        assertEq(cf.accruedFees(), 1 ether);
    }

    function test_Withdraw_ZeroFee() public {
        vm.prank(owner);
        cf.setFee(0);
        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(creator.balance, GOAL);
        assertEq(cf.accruedFees(), 0);
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimFees();
    }

    function test_Withdraw_FeeIsNotChargedOnFailure() public {
        uint256 id = _create();
        _pledge(alice, id, 3 ether);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(id);
        assertEq(alice.balance, 1000 ether); // full pledge back, no fee
        assertEq(cf.accruedFees(), 0);
    }

    function test_Withdraw_FeesAccumulateAcrossCampaigns() public {
        uint256 a = _create();
        vm.prank(bob);
        uint256 b = cf.createCampaign(GOAL, deadline, 1000);
        _pledge(alice, a, 10 ether);
        _pledge(alice, b, 20 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(a);
        vm.prank(bob);
        cf.withdraw(b);
        assertEq(cf.accruedFees(), 0.8 ether + 1.6 ether);
    }

    function testFuzz_Withdraw_ExactSplit(uint256 raised, uint16 feeBps) public {
        raised = bound(raised, 10 ether, 100_000 ether);
        feeBps = uint16(bound(feeBps, 0, 1000));
        vm.prank(owner);
        cf.setFee(feeBps);

        vm.deal(alice, raised);
        uint256 id = _create();
        _pledge(alice, id, raised);
        vm.warp(deadline);

        uint256 expectedFee = (raised * feeBps) / 10_000;
        vm.prank(creator);
        cf.withdraw(id);

        assertEq(cf.accruedFees(), expectedFee, "fee");
        assertEq(creator.balance, raised - expectedFee, "creator");
        assertEq(address(cf).balance, expectedFee, "contract keeps exactly the fee");
        assertLe(expectedFee * 10_000, raised * 1000, "fee never above 10%");
    }

    // ---------------------------------------------------------------- claimFees

    function test_ClaimFees_PaysRecipientAndClears() public {
        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id);

        vm.expectEmit(true, false, false, true, address(cf));
        emit Crowdfund.FeesClaimed(recipient, 0.8 ether);
        vm.prank(mallory); // anyone can trigger it
        cf.claimFees();

        assertEq(recipient.balance, 0.8 ether);
        assertEq(mallory.balance, 0); // the caller gets nothing
        assertEq(cf.accruedFees(), 0);
        assertEq(address(cf).balance, 0);

        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimFees(); // nothing left, cannot claim twice
    }

    function test_ClaimFees_RevertsWhenNothingAccrued() public {
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimFees();
    }

    function test_ClaimFees_GoesToCurrentRecipient() public {
        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id);

        vm.prank(owner);
        cf.setFeeRecipient(bob); // changed after the fee accrued
        uint256 before = bob.balance;
        cf.claimFees();
        assertEq(bob.balance - before, 0.8 ether);
        assertEq(recipient.balance, 0);
    }

    function test_ClaimFees_DoesNotTouchCampaignFunds() public {
        uint256 won = _create();
        vm.prank(bob);
        uint256 other = cf.createCampaign(50 ether, deadline, 1000); // still holds pledges
        _pledge(alice, won, GOAL);
        _pledge(alice, other, 7 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(won);

        cf.claimFees();
        assertEq(recipient.balance, 0.8 ether);
        assertEq(address(cf).balance, 7 ether); // the other campaign's money is untouched
        vm.prank(alice);
        cf.refund(other);
        assertEq(address(cf).balance, 0);
    }

    function test_ClaimFees_RejectingRecipientCannotBlockCreatorsOrBackers() public {
        RejectingRecipient bad = new RejectingRecipient();
        vm.prank(owner);
        cf.setFeeRecipient(address(bad));

        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id); // creator is paid even though the recipient cannot receive

        assertEq(creator.balance, 9.2 ether);
        vm.expectRevert(Crowdfund.TransferFailed.selector);
        cf.claimFees();
        assertEq(cf.accruedFees(), 0.8 ether); // nothing lost

        vm.prank(owner);
        cf.setFeeRecipient(recipient); // owner fixes the address
        cf.claimFees();
        assertEq(recipient.balance, 0.8 ether);
    }

    function test_ClaimFees_ReentrantRecipientIsBlockedByGuard() public {
        ReentrantRecipient rr = new ReentrantRecipient(cf);
        vm.prank(owner);
        cf.setFeeRecipient(address(rr));

        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id);
        rr.setId(id);

        cf.claimFees();

        assertEq(address(rr).balance, 0.8 ether); // paid exactly once
        assertEq(rr.hits(), 1);
        assertEq(rr.lastClaimError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(rr.lastWithdrawError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(rr.lastRefundError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(cf.accruedFees(), 0);
    }

    function test_ClaimFees_ForcedEthDoesNotChangeAmount() public {
        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(creator);
        cf.withdraw(id);
        vm.deal(address(cf), address(cf).balance + 5 ether); // forced ETH
        cf.claimFees();
        assertEq(recipient.balance, 0.8 ether);
        assertEq(address(cf).balance, 5 ether);
    }

    // ---------------------------------------------------------------- ownership

    function test_Ownership_RenounceIsDisabledForEveryone() public {
        vm.prank(owner);
        vm.expectRevert(Crowdfund.RenounceDisabled.selector);
        cf.renounceOwnership();

        vm.prank(mallory);
        vm.expectRevert(Crowdfund.RenounceDisabled.selector);
        cf.renounceOwnership();
        assertEq(cf.owner(), owner);
    }

    function test_Ownership_TwoStepTransfer() public {
        vm.prank(owner);
        cf.transferOwnership(bob);
        assertEq(cf.owner(), owner); // not yet
        assertEq(cf.pendingOwner(), bob);

        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.acceptOwnership();

        vm.prank(bob);
        cf.acceptOwnership();
        assertEq(cf.owner(), bob);

        vm.prank(owner); // the old owner has no power left
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        cf.setFee(0);
    }

    // ---------------------------------------------------------------- the owner cannot reach campaign funds

    function test_Owner_CannotMoveCampaignFunds() public {
        uint256 id = _create();
        _pledge(alice, id, 6 ether);
        uint256 ownerBefore = owner.balance;

        // every owner-only function, and none of them sends ETH to the owner
        vm.startPrank(owner);
        cf.setFee(1000);
        cf.setFeeRecipient(bob);
        cf.setCreationPaused(true);
        cf.setCreationPaused(false);
        cf.transferOwnership(alice);
        vm.stopPrank();

        assertEq(owner.balance, ownerBefore);
        assertEq(address(cf).balance, 6 ether);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(id);
        assertEq(alice.balance, 1000 ether);
    }

    function test_Owner_HasNoSpecialPowerOverWithdrawOrRefund() public {
        uint256 id = _create();
        _fundAndEnd(id, GOAL);
        vm.prank(owner);
        vm.expectRevert(Crowdfund.NotCreator.selector);
        cf.withdraw(id);
        vm.prank(owner);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(id);
    }
}
