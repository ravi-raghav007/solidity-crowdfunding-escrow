// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract A2GasBurner {
    receive() external payable {
        while (true) {}
    }
}

contract A2ReturnBomb {
    fallback() external payable {
        assembly {
            return(0, 1000000)
        }
    }
}

contract A2Reverter {
    receive() external payable {
        revert("no");
    }
}

/// recipient that pledges the money back into an active campaign and tries to create campaigns on receipt
contract A2PledgingRecipient {
    Crowdfund cf;
    uint256 target;
    bytes4 public claimErr;
    bytes4 public createErr;

    constructor(Crowdfund c) {
        cf = c;
    }

    function setTarget(uint256 t) external {
        target = t;
    }

    receive() external payable {
        cf.pledge{value: msg.value}(target);
        try cf.claimFees() {} catch (bytes memory d) {
            claimErr = bytes4(d);
        }
        try cf.createCampaign(1 ether, block.timestamp + 2 days, 1000) {} catch (bytes memory d) {
            createErr = bytes4(d);
        }
    }
}

/// creator that, on payout, pledges to other campaigns / its own / claims fees
contract A2Creator {
    Crowdfund cf;
    uint256 public own;
    uint256 public other;
    bytes4 public ownErr;
    bytes4 public claimErr;
    bytes4 public wdErr;
    bool public reject;

    constructor(Crowdfund c) {
        cf = c;
    }

    function make(uint256 goal, uint256 dl) external returns (uint256 id) {
        id = cf.createCampaign(goal, dl, 1000);
        own = id;
    }

    function setOther(uint256 o) external {
        other = o;
    }

    function setReject(bool r) external {
        reject = r;
    }

    function doWithdraw(uint256 id) external {
        cf.withdraw(id);
    }

    receive() external payable {
        if (reject) revert();
        try cf.pledge{value: msg.value / 2}(own) {} catch (bytes memory d) {
            ownErr = bytes4(d);
        }
        if (other != 0) cf.pledge{value: msg.value / 2}(other);
        try cf.claimFees() {} catch (bytes memory d) {
            claimErr = bytes4(d);
        }
        try cf.withdraw(own) {} catch (bytes memory d) {
            wdErr = bytes4(d);
        }
    }
}

contract Attack2Test is Test {
    Crowdfund cf;

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800);
        vm.deal(alice, 100_000 ether);
        vm.deal(bob, 100_000 ether);
        deadline = block.timestamp + 7 days;
    }

    function _create(uint256 goal) internal returns (uint256 id) {
        vm.prank(creator);
        id = cf.createCampaign(goal, deadline, 1000);
    }

    function _pledge(address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        cf.pledge{value: amt}(id);
    }

    // ------------------------------------------------ owner attacks

    /// Owner front-runs a creator's createCampaign by raising the fee; creator has no max-fee parameter.
    function test_A2_OwnerFrontRunsCreateWithFeeHike() public {
        // creator signed the tx while the fee was 8%
        assertEq(cf.feeBps(), 800);
        vm.prank(owner);
        cf.setFee(1000); // same block, ordered first
        uint256 id = _create(10 ether);
        assertEq(cf.getCampaign(id).feeBps, 1000); // creator is locked at 10% with no way to refuse
    }

    function test_A2_OwnerCannotChangeExistingCampaignFeeBeforeWithdraw() public {
        uint256 id = _create(10 ether);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        vm.startPrank(owner);
        cf.setFee(1000);
        cf.setFeeRecipient(mallory);
        cf.setCreationPaused(true);
        vm.stopPrank();
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(creator.balance, 9.2 ether);
        assertEq(cf.accruedFees(), 0.8 ether);
    }

    function test_A2_OwnerFrontRunsClaimRedirectsAccruedFees() public {
        uint256 id = _create(10 ether);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        vm.prank(owner);
        cf.setFeeRecipient(owner);
        cf.claimFees();
        assertEq(owner.balance, 0.8 ether); // documented: only fees, never campaign funds
        assertEq(recipient.balance, 0);
    }

    function test_A2_OwnerCannotTakeMoreThanAccrued() public {
        uint256 a = _create(10 ether);
        vm.prank(bob);
        uint256 b = cf.createCampaign(500 ether, deadline, 1000);
        _pledge(alice, a, 10 ether);
        _pledge(alice, b, 100 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(a);
        vm.prank(owner);
        cf.setFeeRecipient(owner);
        cf.claimFees();
        assertEq(owner.balance, 0.8 ether);
        assertEq(address(cf).balance, 100 ether);
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimFees();
    }

    function test_A2_SetFeeDirtyCalldataRejected() public {
        // 0x10000 + 5 would truncate to 5 if decoder were lax; ABI decoder must revert
        bytes memory data = abi.encodePacked(Crowdfund.setFee.selector, uint256(0x10000 + 5));
        vm.prank(owner);
        (bool ok,) = address(cf).call(data);
        assertFalse(ok);
        // value 0x10000+2000 would be > cap if not truncated; also rejected
        data = abi.encodePacked(Crowdfund.setFee.selector, uint256(type(uint256).max));
        vm.prank(owner);
        (ok,) = address(cf).call(data);
        assertFalse(ok);
        assertEq(cf.feeBps(), 800);
    }

    function test_A2_SetFeeRecipientToCfItselfCannotClaim() public {
        uint256 id = _create(10 ether);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        // Fixed after the stage 3 review: the contract itself can no longer be the fee recipient.
        vm.prank(owner);
        vm.expectRevert(Crowdfund.InvalidRecipient.selector);
        cf.setFeeRecipient(address(cf));
        assertEq(cf.accruedFees(), 0.8 ether);
    }

    function test_A2_PauseCannotLockFunds() public {
        uint256 id = _create(10 ether);
        _pledge(alice, id, 3 ether);
        vm.prank(owner);
        cf.setCreationPaused(true);
        _pledge(bob, id, 8 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        cf.claimFees();
        assertEq(address(cf).balance, 0);
    }

    // ------------------------------------------------ ownership

    function test_A2_OwnerRenounceViaAnyCaller() public {
        address[3] memory callers = [owner, mallory, address(0)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(Crowdfund.RenounceDisabled.selector);
            cf.renounceOwnership();
        }
        assertEq(cf.owner(), owner);
    }

    function test_A2_TransferToZeroThenNobodyCanAccept() public {
        vm.prank(owner);
        cf.transferOwnership(address(0));
        assertEq(cf.pendingOwner(), address(0));
        assertEq(cf.owner(), owner);
        // OZ quirk: pendingOwner == 0 and sender == 0 passes the check. Only a tx from address(0) could do it
        // (no key exists), so it is unreachable on a real chain. Record what happens.
        vm.prank(address(0));
        cf.acceptOwnership();
        assertEq(cf.owner(), address(0)); // owner bricked IF address(0) could ever send a tx
    }

    function test_A2_AcceptByWrongAddressAndOverwritePending() public {
        vm.startPrank(owner);
        cf.transferOwnership(bob);
        cf.transferOwnership(mallory); // overwrite
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        cf.acceptOwnership();
        vm.prank(mallory);
        cf.acceptOwnership();
        assertEq(cf.owner(), mallory);
        assertEq(cf.pendingOwner(), address(0));
        // second accept impossible
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.acceptOwnership();
    }

    function test_A2_TransferToContractThatCannotAcceptKeepsOwner() public {
        address rev = address(new A2Reverter());
        vm.prank(owner);
        cf.transferOwnership(rev);
        vm.prank(owner);
        cf.setFee(0); // owner still fully in control
        vm.prank(owner);
        cf.transferOwnership(address(0)); // cancel
        assertEq(cf.pendingOwner(), address(0));
    }

    function test_A2_PendingOwnerHasNoPowerBeforeAccept() public {
        vm.prank(owner);
        cf.transferOwnership(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        cf.setFee(0);
    }

    function test_A2_OwnerTransfersToSelfThenAccept() public {
        vm.startPrank(owner);
        cf.transferOwnership(owner);
        cf.acceptOwnership();
        vm.stopPrank();
        assertEq(cf.owner(), owner);
        assertEq(cf.pendingOwner(), address(0));
    }

    // ------------------------------------------------ malicious fee recipient

    function _accrue() internal returns (uint256 id) {
        id = _create(10 ether);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
    }

    function test_A2_GasBurnerRecipientDoesNotBlockOthers() public {
        address burner = address(new A2GasBurner());
        vm.prank(owner);
        cf.setFeeRecipient(burner);
        uint256 id = _create(10 ether);
        _pledge(alice, id, 10 ether);
        // another campaign that fails
        vm.prank(bob);
        uint256 f = cf.createCampaign(1000 ether, deadline, 1000);
        _pledge(alice, f, 2 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        vm.prank(alice);
        cf.refund(f);
        vm.expectRevert(); // out of gas inside recipient => TransferFailed
        cf.claimFees{gas: 500_000}();
        assertEq(cf.accruedFees(), 0.8 ether);
        // recover
        vm.prank(owner);
        cf.setFeeRecipient(recipient);
        cf.claimFees();
        assertEq(recipient.balance, 0.8 ether);
    }

    function test_A2_ReturnBombRecipientIsHarmless() public {
        address bomb = address(new A2ReturnBomb());
        vm.prank(owner);
        cf.setFeeRecipient(bomb);
        _accrue();
        uint256 g = gasleft();
        cf.claimFees();
        uint256 used = g - gasleft();
        assertGt(used, 0);
        assertEq(cf.accruedFees(), 0);
    }

    function test_A2_RecipientPledgesBackAndReentersOthers() public {
        A2PledgingRecipient r = new A2PledgingRecipient(cf);
        vm.prank(owner);
        cf.setFeeRecipient(address(r));
        vm.prank(bob);
        uint256 open = cf.createCampaign(1000 ether, block.timestamp + 30 days, 1000);
        r.setTarget(open);
        _accrue();
        cf.claimFees();
        assertEq(cf.pledgeOf(open, address(r)), 0.8 ether);
        assertEq(address(cf).balance, 0.8 ether);
        assertEq(cf.accruedFees(), 0);
        assertEq(r.claimErr(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(r.createErr(), bytes4(0)); // createCampaign is allowed in a callback, harmless
    }

    function test_A2_LowGasCallerGriefCannotLoseFees() public {
        _accrue();
        // attacker tries a range of gas limits; either succeeds fully or reverts fully
        for (uint256 g = 30_000; g < 90_000; g += 7_000) {
            uint256 before = address(cf).balance;
            vm.prank(mallory);
            (bool ok,) = address(cf).call{gas: g}(abi.encodeCall(Crowdfund.claimFees, ()));
            if (!ok) {
                assertEq(cf.accruedFees(), 0.8 ether);
                assertEq(address(cf).balance, before);
            } else {
                assertEq(cf.accruedFees(), 0);
                break;
            }
        }
    }

    function test_A2_ClaimTwiceNoDoubleSpend() public {
        _accrue();
        cf.claimFees();
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimFees();
        assertEq(recipient.balance, 0.8 ether);
    }

    // ------------------------------------------------ malicious creator contract

    function test_A2_CreatorReentersDuringPayout() public {
        A2Creator c = new A2Creator(cf);
        uint256 id = c.make(10 ether, deadline);
        vm.prank(bob);
        uint256 open = cf.createCampaign(1000 ether, block.timestamp + 60 days, 1000);
        c.setOther(open);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        c.doWithdraw(id);
        assertEq(c.claimErr(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(c.wdErr(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(c.ownErr(), Crowdfund.CampaignEnded.selector);
        assertEq(cf.accruedFees(), 0.8 ether);
        assertEq(address(cf).balance, 0.8 ether + 4.6 ether);
        assertEq(cf.getCampaign(open).raised, 4.6 ether);
    }

    function test_A2_RejectingCreatorLocksOwnPayoutOnly() public {
        A2Creator c = new A2Creator(cf);
        uint256 id = c.make(10 ether, deadline);
        c.setReject(true);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        vm.expectRevert(Crowdfund.TransferFailed.selector);
        c.doWithdraw(id);
        // funds stay locked, no payee redirect exists, goal reached so no refunds
        assertEq(address(cf).balance, 10 ether);
        assertEq(cf.accruedFees(), 0);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(id);
        c.setReject(false); // creator can fix it itself
        c.doWithdraw(id);
    }

    // ------------------------------------------------ rounding / math

    function test_A2_GoalOneWeiAllFees() public {
        vm.prank(owner);
        cf.setFee(1000);
        for (uint256 i; i < 25; ++i) {
            vm.prank(creator);
            uint256 id = cf.createCampaign(1, deadline, 1000);
            _pledge(alice, id, i + 1);
            vm.warp(deadline);
            uint256 before = creator.balance;
            vm.prank(creator);
            cf.withdraw(id);
            uint256 fee = (i + 1) / 10;
            assertEq(creator.balance - before, i + 1 - fee);
            assertEq(cf.getCampaign(id).raised - fee, i + 1 - fee);
            deadline = block.timestamp + 7 days;
        }
    }

    function test_A2_HugeRaisedNoOverflow() public {
        vm.prank(owner);
        cf.setFee(1000);
        uint256 id = _create(1);
        uint256 huge = type(uint256).max / 2;
        vm.deal(alice, huge);
        _pledge(alice, id, huge);
        vm.warp(deadline);
        uint256 before = address(cf).balance;
        vm.prank(creator);
        cf.withdraw(id);
        uint256 fee = cf.accruedFees();
        assertEq(fee, huge / 10 + ((huge % 10 * 1000) / 10_000)); // floor(huge*1000/10000)
        assertEq(creator.balance + fee, huge);
        assertEq(address(cf).balance, before - creator.balance);
    }

    function test_A2_HugeRaisedPledgeOverflowReverts() public {
        uint256 id = _create(1);
        vm.deal(alice, type(uint256).max);
        _pledge(alice, id, type(uint256).max - 5);
        vm.deal(bob, 10);
        vm.prank(bob);
        (bool ok,) = address(cf).call{value: 10}(abi.encodeCall(Crowdfund.pledge, (id)));
        assertFalse(ok); // overflow only at 2^256 wei, unreachable on mainnet
    }

    function testFuzz_A2_SplitConserved(uint256 raised, uint16 bpsIn, uint8 nPledgers) public {
        raised = bound(raised, 1, 1_000_000 ether);
        uint16 bps = uint16(bound(bpsIn, 0, 1000));
        uint256 n = bound(nPledgers, 1, 7);
        vm.prank(owner);
        cf.setFee(bps);
        vm.prank(creator);
        uint256 id = cf.createCampaign(raised, deadline, 1000);
        uint256 part = raised / n;
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 amt = i == n - 1 ? raised - sum : part;
            sum += amt;
            if (amt == 0) continue;
            address p = address(uint160(0x1000 + i));
            vm.deal(p, amt);
            _pledge(p, id, amt);
        }
        vm.warp(deadline);
        uint256 balBefore = address(cf).balance;
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(creator.balance + cf.accruedFees(), raised);
        assertEq(address(cf).balance, balBefore - creator.balance);
        assertLe(cf.accruedFees() * 10_000, raised * 1000);
    }

    // ------------------------------------------------ stateful solvency with owner shenanigans

    function testFuzz_A2_SolvencyUnderRandomSequence(uint256 seed) public {
        uint256[] memory ids = new uint256[](6);
        uint256[] memory goals = new uint256[](6);
        address[3] memory backers = [alice, bob, mallory];
        vm.deal(mallory, 100_000 ether);
        uint256 totalClaimed;
        uint256 owed;
        for (uint256 step; step < 40; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = seed % 8;
            uint256 k = (seed >> 8) % 6;
            if (op == 0 && ids[k] == 0) {
                goals[k] = 1 + ((seed >> 16) % 50 ether);
                vm.prank(creator);
                try cf.createCampaign(goals[k], block.timestamp + 1 days + ((seed >> 80) % 30 days), 1000) returns (
                    uint256 nid
                ) {
                    ids[k] = nid;
                } catch {}
            } else if (op == 1 && ids[k] != 0) {
                uint256 amt = 1 + ((seed >> 16) % 20 ether);
                address b = backers[(seed >> 100) % 3];
                vm.prank(b);
                try cf.pledge{value: amt}(ids[k]) {} catch {}
            } else if (op == 2) {
                vm.warp(block.timestamp + ((seed >> 16) % 10 days));
            } else if (op == 3 && ids[k] != 0) {
                vm.prank(creator);
                try cf.withdraw(ids[k]) {} catch {}
            } else if (op == 4 && ids[k] != 0) {
                vm.prank(backers[(seed >> 100) % 3]);
                try cf.refund(ids[k]) {} catch {}
            } else if (op == 5) {
                vm.prank(owner);
                cf.setFee(uint16((seed >> 16) % 1001));
            } else if (op == 6) {
                uint256 before = recipient.balance;
                try cf.claimFees() {} catch {}
                totalClaimed += recipient.balance - before;
            } else if (op == 7) {
                vm.prank(owner);
                cf.setCreationPaused((seed >> 16) % 2 == 0);
            }
            // solvency
            owed = 0;
            for (uint256 j; j < 6; ++j) {
                if (ids[j] == 0) continue;
                Crowdfund.Campaign memory c = cf.getCampaign(ids[j]);
                if (block.timestamp >= c.deadline && c.raised >= c.goal) {
                    if (!c.paidOut) owed += c.raised;
                } else if (block.timestamp >= c.deadline) {
                    owed += c.raised - c.refunded;
                } else {
                    owed += c.raised;
                }
            }
            assertGe(address(cf).balance, cf.accruedFees() + owed, "insolvent");
            assertEq(address(cf).balance, cf.accruedFees() + owed, "exact (no forced eth)");
        }
    }

    // ------------------------------------------------ views

    function test_A2_ViewsAtBoundaries() public {
        uint256 id = _create(10 ether);
        assertEq(uint8(cf.statusOf(id)), 0);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline - 1);
        assertEq(uint8(cf.statusOf(id)), 0);
        vm.warp(deadline);
        assertEq(uint8(cf.statusOf(id)), 1);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(uint8(cf.statusOf(id)), 2);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.statusOf(0);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.getCampaign(99);
        assertEq(cf.pledgeOf(99, alice), 0);
    }

    function test_A2_WithdrawEventMatchesBalances() public {
        uint256 id = _create(10 ether);
        _pledge(alice, id, 7 ether);
        _pledge(bob, id, 3 ether + 7);
        vm.warp(deadline);
        uint256 total = 10 ether + 7;
        uint256 fee = total * 800 / 10_000;
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Withdrawn(id, creator, 10 ether + 7 - fee, fee);
        vm.prank(creator);
        cf.withdraw(id);
    }

    function test_A2_PendingFeesSurviveDeepFeeChanges() public {
        uint256 id = _create(10 ether);
        _pledge(alice, id, 10 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        vm.prank(owner);
        cf.setFee(0);
        assertEq(cf.accruedFees(), 0.8 ether);
        cf.claimFees();
        assertEq(recipient.balance, 0.8 ether);
    }
}

contract A2MemOnly {
    fallback() external payable {
        assembly {
            mstore(1000000, 1)
            return(1000000, 1)
            
        }
    }
}

contract Attack2ReturnData is Test {
    function _cost(address rcpt) internal returns (uint256 used) {
        vm.warp(1_000_000);
        Crowdfund cf = new Crowdfund(address(this), rcpt, 1000);
        address creator = address(0xC1);
        vm.prank(creator);
        uint256 id = cf.createCampaign(1 ether, block.timestamp + 2 days, 1000);
        vm.deal(address(0xA1), 1 ether);
        vm.prank(address(0xA1));
        cf.pledge{value: 1 ether}(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(creator);
        cf.withdraw(id);
        uint256 g = gasleft();
        cf.claimFees();
        used = g - gasleft();
    }

    function test_A2_ReturnBombCopyCostVsMemOnly() public {
        uint256 bomb = _cost(address(new A2ReturnBomb()));
        uint256 memOnly = _cost(address(new A2MemOnly()));
        emit log_named_uint("bomb gas", bomb);
        emit log_named_uint("memOnly gas", memOnly);
        // Fixed after the stage 2 review: the contract sends ETH with a zero-size return buffer, so a
        // 1MB return payload costs essentially nothing extra (was over 2M gas more before the fix).
        assertLe(bomb, memOnly + 50_000, "return data must not be copied");
    }
}

contract A2SizedBomb {
    uint256 immutable size;
    bool immutable copyIt;

    constructor(uint256 s, bool c) {
        size = s;
        copyIt = c;
    }

    fallback() external payable {
        uint256 s = size;
        if (copyIt) {
            assembly {
                return(0, s)
            }
        } else {
            assembly {
                mstore(s, 1)
                return(s, 1)
            }
        }
    }
}

contract Attack2ReturnBlock is Test {
    function _try(address rcpt) internal returns (bool ok) {
        vm.warp(1_000_000);
        Crowdfund cf = new Crowdfund(address(this), rcpt, 1000);
        address creator = address(0xC1);
        vm.prank(creator);
        uint256 id = cf.createCampaign(1 ether, block.timestamp + 2 days, 1000);
        vm.deal(address(0xA1), 1 ether);
        vm.prank(address(0xA1));
        cf.pledge{value: 1 ether}(id);
        vm.warp(block.timestamp + 2 days);
        vm.prank(creator);
        cf.withdraw(id);
        (ok,) = address(cf).call{gas: 30_000_000}(abi.encodeCall(Crowdfund.claimFees, ()));
    }

    /// Same memory footprint in the recipient; only the returndata copy in claimFees differs.
    function test_A2_ReturnBombBlocksClaimFeesAt30MGas() public {
        uint256 size = 3_000_000;
        bool honest = _try(address(new A2SizedBomb(size, false)));
        bool bomb = _try(address(new A2SizedBomb(size, true)));
        emit log_named_string("recipient w/o 3MB return claim ok", honest ? "true" : "false");
        emit log_named_string("recipient returning 3MB claim ok", bomb ? "true" : "false");
        assertTrue(honest);
        assertTrue(bomb, "a recipient returning 3MB must not be able to block claimFees");
    }
}
