// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {MockToken, MisdeliveringToken} from "./helpers/TestTokens.sol";

/// Tests added after the independent stage 3 reviews (see docs/REVIEW-03.md).
contract CrowdfundTokenExtraTest is Test {
    Crowdfund cf;
    MockToken tokenA; // 6 decimals
    MockToken tokenB; // 18 decimals

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800);
        tokenA = new MockToken("Token A", "AAA", 6);
        tokenB = new MockToken("Token B", "BBB", 18);
        vm.startPrank(owner);
        cf.setTokenAllowed(address(tokenA), true);
        cf.setTokenAllowed(address(tokenB), true);
        vm.stopPrank();
        deadline = block.timestamp + 7 days;
        _fund(tokenA, alice, 1_000_000e6);
        _fund(tokenB, alice, 1_000_000 ether);
        _fund(tokenA, bob, 1_000_000e6);
        _fund(tokenB, bob, 1_000_000 ether);
    }

    function _fund(MockToken t, address who, uint256 amount) internal {
        t.mint(who, amount);
        vm.prank(who);
        t.approve(address(cf), type(uint256).max);
    }

    // ---------------------------------------------------------------- the exact-received check works in both directions

    function test_OverDelivery_IsRejectedToo() public {
        MisdeliveringToken t = new MisdeliveringToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(t), true);
        t.mint(alice, 1000 ether);
        vm.prank(alice);
        t.approve(address(cf), type(uint256).max);
        vm.prank(creator);
        uint256 id = cf.createTokenCampaign(500 ether, deadline, 1000, address(t));

        t.setDelta(1); // the token delivers exactly one unit MORE than the amount
        vm.prank(alice);
        vm.expectRevert(Crowdfund.UnsupportedToken.selector);
        cf.pledgeToken(id, 10 ether);
        assertEq(cf.getCampaign(id).raised, 0);
        assertEq(t.balanceOf(address(cf)), 0);

        t.setDelta(-1); // one unit LESS
        vm.prank(alice);
        vm.expectRevert(Crowdfund.UnsupportedToken.selector);
        cf.pledgeToken(id, 10 ether);

        t.setDelta(0); // exactly right
        vm.prank(alice);
        cf.pledgeToken(id, 10 ether);
        assertEq(cf.getCampaign(id).raised, 10 ether);
    }

    function testFuzz_Misdelivery_OnlyExactDeliveryIsAccepted(uint256 amount, int256 delta) public {
        amount = bound(amount, 1 ether, 1_000 ether);
        delta = bound(delta, -int256(amount) + 1, 1000 ether);
        MisdeliveringToken t = new MisdeliveringToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(t), true);
        t.mint(alice, 5000 ether);
        vm.prank(alice);
        t.approve(address(cf), type(uint256).max);
        vm.prank(creator);
        uint256 id = cf.createTokenCampaign(1 ether, deadline, 1000, address(t));

        t.setDelta(delta);
        vm.prank(alice);
        if (delta == 0) {
            cf.pledgeToken(id, amount);
            assertEq(cf.getCampaign(id).raised, amount);
            assertEq(t.balanceOf(address(cf)), amount);
        } else {
            vm.expectRevert(Crowdfund.UnsupportedToken.selector);
            cf.pledgeToken(id, amount);
            assertEq(cf.getCampaign(id).raised, 0);
            assertEq(t.balanceOf(address(cf)), 0);
        }
    }

    // ---------------------------------------------------------------- two different tokens in one contract

    function test_TwoTokens_FeesAndBalancesStaySeparate() public {
        vm.prank(creator);
        uint256 idA = cf.createTokenCampaign(10_000e6, deadline, 1000, address(tokenA));
        vm.prank(creator);
        uint256 idB = cf.createTokenCampaign(100 ether, deadline, 1000, address(tokenB));

        vm.prank(alice);
        cf.pledgeToken(idA, 10_000e6);
        vm.prank(bob);
        cf.pledgeToken(idB, 100 ether);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(idA); // only A is paid out

        assertEq(cf.accruedTokenFees(address(tokenA)), 800e6);
        assertEq(cf.accruedTokenFees(address(tokenB)), 0); // B's counter is untouched
        assertEq(tokenA.balanceOf(creator), 9200e6);
        assertEq(tokenB.balanceOf(creator), 0);

        // B has no fee to claim, and claiming A touches only A
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimTokenFees(address(tokenB));
        cf.claimTokenFees(address(tokenA));
        assertEq(tokenA.balanceOf(recipient), 800e6);
        assertEq(tokenB.balanceOf(recipient), 0);
        assertEq(tokenB.balanceOf(address(cf)), 100 ether); // campaign B's money is untouched

        vm.prank(creator);
        cf.withdraw(idB);
        assertEq(cf.accruedTokenFees(address(tokenB)), 8 ether); // 8% of 100
        cf.claimTokenFees(address(tokenB));
        assertEq(tokenB.balanceOf(recipient), 8 ether);
        assertEq(tokenA.balanceOf(address(cf)), 0);
        assertEq(tokenB.balanceOf(address(cf)), 0);
    }

    function test_TwoTokens_RefundsComeBackInTheRightToken() public {
        vm.prank(creator);
        uint256 idA = cf.createTokenCampaign(1_000_000e6, deadline, 1000, address(tokenA));
        vm.prank(creator);
        uint256 idB = cf.createTokenCampaign(1_000_000 ether, deadline, 1000, address(tokenB));
        vm.startPrank(alice);
        cf.pledgeToken(idA, 5e6);
        cf.pledgeToken(idB, 7 ether);
        vm.stopPrank();
        vm.warp(deadline);

        vm.prank(alice);
        cf.refund(idB);
        assertEq(tokenB.balanceOf(alice), 1_000_000 ether);
        assertEq(tokenA.balanceOf(address(cf)), 5e6); // A is untouched
        vm.prank(alice);
        cf.refund(idA);
        assertEq(tokenA.balanceOf(alice), 1_000_000e6);
    }

    // ---------------------------------------------------------------- allow-list needs a real contract

    function test_Allow_RejectsAnAddressWithoutCode() public {
        vm.startPrank(owner);
        vm.expectRevert(Crowdfund.InvalidToken.selector);
        cf.setTokenAllowed(makeAddr("anEoa"), true);
        vm.expectRevert(Crowdfund.InvalidToken.selector);
        cf.setTokenAllowed(address(cf), true);
        vm.stopPrank();
    }

    function test_Allow_ZeroAddressIsCheckedBeforeCode() public {
        vm.prank(owner);
        vm.expectRevert(Crowdfund.ZeroAddress.selector);
        cf.setTokenAllowed(address(0), true);
    }

    function test_Allow_DisallowingAnyAddressIsAlwaysPossible() public {
        // removing an entry never depends on the address still having code (a token whose code is gone can be cleaned up)
        address ghost = makeAddr("ghost");
        vm.prank(owner);
        cf.setTokenAllowed(ghost, false);
        assertFalse(cf.allowedToken(ghost));

        vm.etch(address(tokenA), ""); // the token's code disappears after it was allowed
        vm.prank(owner);
        cf.setTokenAllowed(address(tokenA), false);
        assertFalse(cf.allowedToken(address(tokenA)));
    }

    // ---------------------------------------------------------------- claiming to the token itself

    function test_ClaimTokenFees_RecipientEqualToTheTokenRevertsAndKeepsTheFees() public {
        vm.prank(creator);
        uint256 id = cf.createTokenCampaign(10_000e6, deadline, 1000, address(tokenA));
        vm.prank(alice);
        cf.pledgeToken(id, 10_000e6);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);

        vm.prank(owner);
        cf.setFeeRecipient(address(tokenA)); // an owner mistake
        vm.expectRevert(Crowdfund.InvalidRecipient.selector);
        cf.claimTokenFees(address(tokenA));
        assertEq(cf.accruedTokenFees(address(tokenA)), 800e6); // nothing lost, nothing sent

        vm.prank(owner);
        cf.setFeeRecipient(recipient);
        cf.claimTokenFees(address(tokenA));
        assertEq(tokenA.balanceOf(recipient), 800e6);
    }
}
