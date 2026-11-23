// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Creator that tries to re-enter claimFees() while its own payout is being sent.
contract ClaimingCreator {
    Crowdfund public cf;
    bytes4 public err;
    bool public claimedOk;

    constructor(Crowdfund _cf) {
        cf = _cf;
    }

    function create(uint256 goal, uint256 dl) external returns (uint256) {
        return cf.createCampaign(goal, dl, 1000);
    }

    function go(uint256 id) external {
        cf.withdraw(id);
    }

    receive() external payable {
        try cf.claimFees() {
            claimedOk = true;
        } catch (bytes memory d) {
            if (d.length >= 4) {
                bytes4 s;
                assembly {
                    s := mload(add(d, 32))
                }
                err = s;
            }
        }
    }
}

/// Second group of stage 2 tests: fee slippage protection, events, check order, ownership details.
/// (Most of these came out of the independent stage 2 reviews, see docs/REVIEW-02.md.)
contract CrowdfundFeeExtraTest is Test {
    Crowdfund cf;
    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address mallory = makeAddr("mallory");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800);
        vm.deal(alice, 100 ether);
    }

    // ---------------------------------------------------------------- fee slippage protection (maxFeeBps)

    function test_MaxFee_CreationRevertsIfFeeIsAboveWhatCreatorAccepts() public {
        vm.prank(creator);
        vm.expectRevert(Crowdfund.FeeAboveMax.selector);
        cf.createCampaign(1 ether, block.timestamp + 2 days, 799); // current fee is 800
    }

    function test_MaxFee_BoundaryIsInclusive() public {
        vm.prank(creator);
        uint256 id = cf.createCampaign(1 ether, block.timestamp + 2 days, 800);
        assertEq(cf.getCampaign(id).feeBps, 800);
    }

    function test_MaxFee_ProtectsCreatorFromOwnerFrontRunning() public {
        // The creator agreed to 8%. The owner raises the fee to 10% just before the creation lands.
        vm.prank(owner);
        cf.setFee(1000);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.FeeAboveMax.selector);
        cf.createCampaign(1 ether, block.timestamp + 2 days, 800);
        assertEq(cf.campaignCount(), 0); // nothing was created at the higher fee
    }

    function test_MaxFee_ZeroMaxMeansFreeCampaignsOnly() public {
        vm.prank(creator);
        vm.expectRevert(Crowdfund.FeeAboveMax.selector);
        cf.createCampaign(1 ether, block.timestamp + 2 days, 0);
        vm.prank(owner);
        cf.setFee(0);
        vm.prank(creator);
        cf.createCampaign(1 ether, block.timestamp + 2 days, 0);
    }

    function test_Order_Create_PausedBeforeFeeAboveMax() public {
        vm.prank(owner);
        cf.setCreationPaused(true);
        vm.expectRevert(Crowdfund.CreationPaused.selector);
        cf.createCampaign(0, 0, 0);
    }

    function test_Order_Create_ZeroGoalBeforeFeeAboveMax() public {
        vm.expectRevert(Crowdfund.ZeroGoal.selector);
        cf.createCampaign(0, block.timestamp + 2 days, 0);
    }

    function test_Order_Create_InvalidDeadlineBeforeFeeAboveMax() public {
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createCampaign(1, 0, 0);
    }

    // ---------------------------------------------------------------- pause event

    function test_Pause_EmitsEventWithTheNewValue() public {
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(cf));
        emit Crowdfund.CreationPausedUpdated(true);
        cf.setCreationPaused(true);

        vm.expectEmit(false, false, false, true, address(cf));
        emit Crowdfund.CreationPausedUpdated(false);
        cf.setCreationPaused(false);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- check order of admin functions

    function test_Order_Constructor_OwnerBeforeRecipientBeforeFee() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Crowdfund(address(0), address(0), 5000);

        vm.expectRevert(Crowdfund.ZeroAddress.selector);
        new Crowdfund(owner, address(0), 5000);
    }

    function test_Order_Admin_NotOwnerBeforeBadValue() public {
        vm.startPrank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.setFee(5000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.setFeeRecipient(address(0));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- ownership details

    function test_Ownership_NonOwnerCannotStartTransfer() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.transferOwnership(mallory);
    }

    function test_Ownership_PendingOwnerHasNoRightsUntilAcceptAndClearsAfter() public {
        vm.prank(owner);
        cf.transferOwnership(alice);
        assertEq(cf.pendingOwner(), alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cf.setFee(1);

        vm.prank(alice);
        cf.acceptOwnership();
        assertEq(cf.owner(), alice);
        assertEq(cf.pendingOwner(), address(0));
    }

    function test_Ownership_OwnerCanCancelAPendingTransfer() public {
        vm.startPrank(owner);
        cf.transferOwnership(alice);
        cf.transferOwnership(address(0));
        vm.stopPrank();
        assertEq(cf.pendingOwner(), address(0));
        assertEq(cf.owner(), owner);
    }

    function test_Ownership_RenounceStaysDisabledWhileTransferIsPending() public {
        vm.startPrank(owner);
        cf.transferOwnership(alice);
        vm.expectRevert(Crowdfund.RenounceDisabled.selector);
        cf.renounceOwnership();
        vm.stopPrank();
        assertEq(cf.owner(), owner);
    }

    // ---------------------------------------------------------------- creator re-entering claimFees

    function test_Reentrancy_CreatorCannotClaimFeesDuringItsOwnPayout() public {
        ClaimingCreator cc = new ClaimingCreator(cf);
        uint256 dl = block.timestamp + 2 days;
        uint256 id = cc.create(10 ether, dl);
        vm.prank(alice);
        cf.pledge{value: 10 ether}(id);
        vm.warp(dl);

        cc.go(id);

        assertFalse(cc.claimedOk());
        assertEq(cc.err(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(cf.accruedFees(), 0.8 ether);
        assertEq(address(cc).balance, 9.2 ether);
    }

    // ---------------------------------------------------------------- ABI layout the interface depends on

    /// The order of the fields returned by getCampaign is part of the interface (spec 02).
    function test_Abi_GetCampaignFieldOrder() public {
        vm.prank(creator);
        uint256 id = cf.createCampaign(7, block.timestamp + 2 days, 1000);
        (bool ok, bytes memory data) = address(cf).staticcall(abi.encodeCall(Crowdfund.getCampaign, (id)));
        assertTrue(ok);
        (address c, uint64 dl, uint16 fee, bool paid, uint256 goal, uint256 raised, uint256 refunded) =
            abi.decode(data, (address, uint64, uint16, bool, uint256, uint256, uint256));
        assertEq(c, creator);
        assertEq(dl, uint64(block.timestamp + 2 days));
        assertEq(fee, 800);
        assertFalse(paid);
        assertEq(goal, 7);
        assertEq(raised, 0);
        assertEq(refunded, 0);
    }

    // ---------------------------------------------------------------- recipient edge cases

    /// Changed after the stage 3 reviews: the contract itself is never a valid fee recipient, because token fees
    /// sent to it would be stranded. The check applies in the constructor and in setFeeRecipient.
    function test_Recipient_CannotBeTheContractItself() public {
        vm.prank(owner);
        vm.expectRevert(Crowdfund.InvalidRecipient.selector);
        cf.setFeeRecipient(address(cf));
        assertEq(cf.feeRecipient(), recipient); // unchanged

        // the constructor rejects the address the new contract is about to get
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(Crowdfund.InvalidRecipient.selector);
        new Crowdfund(owner, predicted, 100);
    }

    function test_Order_Recipient_ZeroBeforeContractItself() public {
        vm.prank(owner);
        vm.expectRevert(Crowdfund.ZeroAddress.selector);
        cf.setFeeRecipient(address(0));
    }
}
