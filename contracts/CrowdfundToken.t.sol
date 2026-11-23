// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {
    MockToken,
    FeeOnTransferToken,
    NoReturnToken,
    FalseReturnToken,
    BlocklistToken,
    HookToken
} from "./helpers/TestTokens.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CrowdfundTokenTest is Test {
    Crowdfund cf;
    MockToken usdc;

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant GOAL = 10_000e6; // 10,000 USDC (6 decimals)
    uint256 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800); // 8%
        usdc = new MockToken("USD Coin", "USDC", 6);
        vm.prank(owner);
        cf.setTokenAllowed(address(usdc), true);
        _fund(usdc, alice);
        _fund(usdc, bob);
        deadline = block.timestamp + 7 days;
    }

    function _fund(MockToken t, address who) internal {
        t.mint(who, 1_000_000_000e6);
        vm.prank(who);
        t.approve(address(cf), type(uint256).max);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(creator);
        id = cf.createTokenCampaign(GOAL, deadline, 1000, address(usdc));
    }

    function _pledge(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        cf.pledgeToken(id, amount);
    }

    // ---------------------------------------------------------------- allow list

    function test_Allow_OnlyOwner() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, mallory));
        cf.setTokenAllowed(address(usdc), false);
    }

    function test_Allow_ZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(Crowdfund.ZeroAddress.selector);
        cf.setTokenAllowed(address(0), true);
    }

    function test_Allow_TogglesAndEmits() public {
        address other = address(new MockToken("Other", "OTH", 18));
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(cf));
        emit Crowdfund.TokenAllowedUpdated(other, true);
        cf.setTokenAllowed(other, true);
        assertTrue(cf.allowedToken(other));

        vm.expectEmit(true, false, false, true, address(cf));
        emit Crowdfund.TokenAllowedUpdated(other, false);
        cf.setTokenAllowed(other, false);
        assertFalse(cf.allowedToken(other));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- creating token campaigns

    function test_CreateToken_StoresTokenAndEmits() public {
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.CampaignCreated(1, creator, GOAL, uint64(deadline), 800, address(usdc));
        uint256 id = _create();
        assertEq(cf.getCampaign(id).token, address(usdc));
        assertEq(cf.getCampaign(id).feeBps, 800);
    }

    function test_CreateToken_RevertsIfTokenNotAllowed() public {
        MockToken other = new MockToken("Other", "OTH", 18);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.TokenNotAllowed.selector);
        cf.createTokenCampaign(GOAL, deadline, 1000, address(other));

        vm.prank(creator);
        vm.expectRevert(Crowdfund.TokenNotAllowed.selector);
        cf.createTokenCampaign(GOAL, deadline, 1000, address(0)); // the zero address is never a valid token
    }

    function test_CreateToken_CheckOrder() public {
        address bad = makeAddr("notAllowed");

        // zero goal beats a disallowed token
        vm.expectRevert(Crowdfund.ZeroGoal.selector);
        cf.createTokenCampaign(0, deadline, 1000, bad);
        // bad deadline beats a disallowed token
        vm.expectRevert(Crowdfund.InvalidDeadline.selector);
        cf.createTokenCampaign(GOAL, 0, 1000, bad);
        // fee above the creator limit beats a disallowed token
        vm.expectRevert(Crowdfund.FeeAboveMax.selector);
        cf.createTokenCampaign(GOAL, deadline, 799, bad);
        // pause beats everything
        vm.prank(owner);
        cf.setCreationPaused(true);
        vm.expectRevert(Crowdfund.CreationPaused.selector);
        cf.createTokenCampaign(0, 0, 0, bad);
    }

    function test_CreateEth_HasNoToken() public {
        vm.prank(creator);
        uint256 id = cf.createCampaign(1 ether, deadline, 1000);
        assertEq(cf.getCampaign(id).token, address(0));
    }

    function test_GetCampaign_TokenIsTheLastField() public {
        uint256 id = _create();
        (bool ok, bytes memory data) = address(cf).staticcall(abi.encodeCall(Crowdfund.getCampaign, (id)));
        assertTrue(ok);
        (address c,, uint16 fee,,,,, address token) =
            abi.decode(data, (address, uint64, uint16, bool, uint256, uint256, uint256, address));
        assertEq(c, creator);
        assertEq(fee, 800);
        assertEq(token, address(usdc));
    }

    // ---------------------------------------------------------------- pledging tokens

    function test_PledgeToken_AccumulatesAndEmits() public {
        uint256 id = _create();
        uint256 before = usdc.balanceOf(alice);

        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Pledged(id, alice, 3000e6);
        _pledge(alice, id, 3000e6);
        _pledge(alice, id, 2000e6);
        _pledge(bob, id, 1000e6);

        assertEq(cf.pledgeOf(id, alice), 5000e6);
        assertEq(cf.pledgeOf(id, bob), 1000e6);
        assertEq(cf.getCampaign(id).raised, 6000e6);
        assertEq(usdc.balanceOf(address(cf)), 6000e6);
        assertEq(before - usdc.balanceOf(alice), 5000e6);
        assertEq(address(cf).balance, 0); // no ETH involved
    }

    function test_PledgeToken_Reverts() public {
        uint256 id = _create();

        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledgeToken(0, 1);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledgeToken(99, 1);

        vm.prank(alice);
        vm.expectRevert(Crowdfund.ZeroAmount.selector);
        cf.pledgeToken(id, 0);

        // not approved
        vm.prank(mallory);
        vm.expectRevert();
        cf.pledgeToken(id, 1);

        // approved but no balance
        vm.startPrank(mallory);
        usdc.approve(address(cf), type(uint256).max);
        vm.expectRevert();
        cf.pledgeToken(id, 1);
        vm.stopPrank();
    }

    function test_PledgeToken_ClosesExactlyAtDeadline() public {
        uint256 id = _create();
        vm.warp(deadline - 1);
        _pledge(alice, id, 1e6);

        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.CampaignEnded.selector);
        cf.pledgeToken(id, 1e6);
    }

    function test_PledgeToken_OnEthCampaignReverts() public {
        vm.prank(creator);
        uint256 ethId = cf.createCampaign(1 ether, deadline, 1000);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.WrongCurrency.selector);
        cf.pledgeToken(ethId, 1e6);
    }

    function test_PledgeToken_CheckOrder() public {
        vm.prank(creator);
        uint256 ethId = cf.createCampaign(1 ether, deadline, 1000);
        uint256 id = _create();

        // unknown id beats everything
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledgeToken(77, 0);
        // wrong currency beats zero amount
        vm.prank(alice);
        vm.expectRevert(Crowdfund.WrongCurrency.selector);
        cf.pledgeToken(ethId, 0);
        // zero amount beats ended
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.ZeroAmount.selector);
        cf.pledgeToken(id, 0);
    }

    function test_PledgeEth_OnTokenCampaignReverts() public {
        uint256 id = _create();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.WrongCurrency.selector);
        cf.pledge{value: 1 ether}(id);
    }

    function test_PledgeEth_CheckOrderWithTokenCampaign() public {
        uint256 id = _create();
        vm.deal(alice, 1 ether);
        // unknown id beats wrong currency
        vm.prank(alice);
        vm.expectRevert(Crowdfund.NoSuchCampaign.selector);
        cf.pledge{value: 1 ether}(99);
        // wrong currency beats zero value
        vm.prank(alice);
        vm.expectRevert(Crowdfund.WrongCurrency.selector);
        cf.pledge{value: 0}(id);
    }

    function test_PledgeToken_RejectsAttachedEth() public {
        uint256 id = _create();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(cf).call{value: 1 ether}(abi.encodeCall(Crowdfund.pledgeToken, (id, 1e6)));
        assertFalse(ok); // pledgeToken is not payable
        assertEq(address(cf).balance, 0);
    }

    // ---------------------------------------------------------------- withdrawing and refunding

    function test_Withdraw_Token_SplitsPayoutAndFee() public {
        uint256 id = _create();
        _pledge(alice, id, 6000e6);
        _pledge(bob, id, 6000e6);
        vm.warp(deadline);

        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Withdrawn(id, creator, 11_040e6, 960e6);
        vm.prank(creator);
        cf.withdraw(id);

        assertEq(usdc.balanceOf(creator), 11_040e6);
        assertEq(cf.accruedTokenFees(address(usdc)), 960e6);
        assertEq(usdc.balanceOf(address(cf)), 960e6); // the fee stays until claimed
        assertEq(cf.accruedFees(), 0); // ETH fee counter untouched
        assertEq(address(cf).balance, 0);
        assertEq(uint256(cf.statusOf(id)), uint256(Crowdfund.Status.Paid));
    }

    function test_Withdraw_Token_OnlyCreatorOnceAfterGoal() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);

        vm.prank(creator);
        vm.expectRevert(Crowdfund.NotEnded.selector);
        cf.withdraw(id);

        vm.warp(deadline);
        vm.prank(mallory);
        vm.expectRevert(Crowdfund.NotCreator.selector);
        cf.withdraw(id);

        vm.startPrank(creator);
        cf.withdraw(id);
        vm.expectRevert(Crowdfund.AlreadyPaid.selector);
        cf.withdraw(id);
        vm.stopPrank();
    }

    function test_Withdraw_Token_GoalOneUnitShortFails() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL - 1);
        vm.warp(deadline);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.GoalNotReached.selector);
        cf.withdraw(id);
    }

    function test_Refund_Token_FullPledgeBackNoFee() public {
        uint256 id = _create();
        _pledge(alice, id, 3000e6);
        _pledge(bob, id, 2000e6);
        vm.warp(deadline);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.Refunded(id, alice, 3000e6);
        vm.prank(alice);
        cf.refund(id);
        assertEq(usdc.balanceOf(alice) - aliceBefore, 3000e6);
        assertEq(usdc.balanceOf(address(cf)), 2000e6);

        vm.prank(bob);
        cf.refund(id);
        assertEq(usdc.balanceOf(address(cf)), 0);
        assertEq(cf.accruedTokenFees(address(usdc)), 0);

        vm.prank(alice);
        vm.expectRevert(Crowdfund.NothingToRefund.selector);
        cf.refund(id);
    }

    function test_Refund_Token_RevertsAfterSuccess() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(id);
    }

    function test_Token_SmallAmountsRoundDownInTheCreatorsFavour() public {
        vm.prank(creator);
        uint256 id = cf.createTokenCampaign(13, deadline, 1000, address(usdc)); // 13 units, 8% = 1.04
        _pledge(alice, id, 13);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(cf.accruedTokenFees(address(usdc)), 1);
        assertEq(usdc.balanceOf(creator), 12);
    }

    // ---------------------------------------------------------------- claiming token fees

    function test_ClaimTokenFees_AnyoneTriggersRecipientGetsPaid() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);

        vm.expectEmit(true, true, false, true, address(cf));
        emit Crowdfund.TokenFeesClaimed(address(usdc), recipient, 800e6);
        vm.prank(mallory);
        cf.claimTokenFees(address(usdc));

        assertEq(usdc.balanceOf(recipient), 800e6);
        assertEq(usdc.balanceOf(mallory), 0);
        assertEq(cf.accruedTokenFees(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(cf)), 0);

        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimTokenFees(address(usdc));
    }

    function test_ClaimTokenFees_NothingForAnUnknownToken() public {
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimTokenFees(makeAddr("whatever"));
    }

    function test_ClaimTokenFees_GoesToTheCurrentRecipient() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);

        vm.prank(owner);
        cf.setFeeRecipient(bob);
        uint256 before = usdc.balanceOf(bob);
        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(bob) - before, 800e6);
    }

    function test_ClaimFees_EthAndTokenAreSeparate() public {
        uint256 tokenId = _create();
        vm.prank(creator);
        uint256 ethId = cf.createCampaign(10 ether, deadline, 1000);
        _pledge(alice, tokenId, GOAL);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        cf.pledge{value: 10 ether}(ethId);
        vm.warp(deadline);
        vm.startPrank(creator);
        cf.withdraw(tokenId);
        cf.withdraw(ethId);
        vm.stopPrank();

        assertEq(cf.accruedFees(), 0.8 ether);
        assertEq(cf.accruedTokenFees(address(usdc)), 800e6);

        cf.claimFees(); // ETH only
        assertEq(recipient.balance, 0.8 ether);
        assertEq(usdc.balanceOf(recipient), 0);
        assertEq(cf.accruedTokenFees(address(usdc)), 800e6);

        cf.claimTokenFees(address(usdc)); // tokens only
        assertEq(usdc.balanceOf(recipient), 800e6);
        assertEq(address(cf).balance, 0);
    }

    function test_ClaimTokenFees_DoesNotTouchOtherCampaignFunds() public {
        uint256 won = _create();
        vm.prank(bob);
        uint256 open = cf.createTokenCampaign(50_000e6, deadline, 1000, address(usdc));
        _pledge(alice, won, GOAL);
        _pledge(alice, open, 7000e6);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(won);

        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(address(cf)), 7000e6); // the other campaign's tokens are untouched
        vm.prank(alice);
        cf.refund(open);
        assertEq(usdc.balanceOf(address(cf)), 0);
    }

    // ---------------------------------------------------------------- allow list never traps existing campaigns

    function test_Disallow_DoesNotTrapAnExistingCampaign() public {
        uint256 id = _create();
        _pledge(alice, id, 4000e6);

        vm.prank(owner);
        cf.setTokenAllowed(address(usdc), false);

        // new campaigns in that token are no longer possible
        vm.prank(creator);
        vm.expectRevert(Crowdfund.TokenNotAllowed.selector);
        cf.createTokenCampaign(GOAL, deadline, 1000, address(usdc));

        // but everything on the existing campaign keeps working
        _pledge(bob, id, 7000e6);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(usdc.balanceOf(creator), 10_120e6);
        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(recipient), 880e6);
    }

    function test_Disallow_DoesNotBlockRefunds() public {
        uint256 id = _create();
        _pledge(alice, id, 1000e6);
        vm.prank(owner);
        cf.setTokenAllowed(address(usdc), false);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(id);
        assertEq(usdc.balanceOf(address(cf)), 0);
    }

    // ---------------------------------------------------------------- the owner and stray tokens

    function test_Owner_CannotMoveTokens() public {
        uint256 id = _create();
        _pledge(alice, id, 6000e6);

        vm.startPrank(owner);
        cf.setFee(1000);
        cf.setFeeRecipient(bob);
        cf.setCreationPaused(true);
        cf.setCreationPaused(false);
        cf.setTokenAllowed(address(usdc), false);
        cf.setTokenAllowed(address(usdc), true);
        vm.stopPrank();

        assertEq(usdc.balanceOf(owner), 0);
        assertEq(usdc.balanceOf(address(cf)), 6000e6);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(id);
        assertEq(usdc.balanceOf(alice), 1_000_000_000e6);
    }

    function test_DirectTokenTransferIsHarmlessAndStuck() public {
        uint256 id = _create();
        _pledge(alice, id, GOAL);
        vm.prank(bob);
        usdc.transfer(address(cf), 123e6); // sent directly, not through pledgeToken

        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(usdc.balanceOf(creator), 9200e6); // exactly raised minus fee, not affected by the stray tokens
        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(recipient), 800e6);
        assertEq(usdc.balanceOf(address(cf)), 123e6); // the stray tokens stay, counted nowhere
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_Token_ExactSplit(uint256 raised, uint16 feeBps) public {
        raised = bound(raised, GOAL, 100_000_000e6);
        feeBps = uint16(bound(feeBps, 0, 1000));
        vm.prank(owner);
        cf.setFee(feeBps);
        usdc.mint(alice, raised);

        uint256 id = _create();
        _pledge(alice, id, raised);
        vm.warp(deadline);

        uint256 expectedFee = (raised * feeBps) / 10_000;
        vm.prank(creator);
        cf.withdraw(id);

        assertEq(cf.accruedTokenFees(address(usdc)), expectedFee, "fee");
        assertEq(usdc.balanceOf(creator), raised - expectedFee, "creator");
        assertEq(usdc.balanceOf(address(cf)), expectedFee, "contract keeps exactly the fee");
    }

    function testFuzz_Token_OutcomeMatchesGoal(uint256 goal, uint256 a, uint256 b) public {
        goal = bound(goal, 1, 1_000_000e6);
        a = bound(a, 1, 600_000e6);
        b = bound(b, 1, 600_000e6);

        vm.prank(creator);
        uint256 id = cf.createTokenCampaign(goal, deadline, 1000, address(usdc));
        _pledge(alice, id, a);
        _pledge(bob, id, b);
        vm.warp(deadline);

        if (a + b >= goal) {
            vm.prank(alice);
            vm.expectRevert(Crowdfund.GoalReached.selector);
            cf.refund(id);
            vm.prank(creator);
            cf.withdraw(id);
            assertEq(usdc.balanceOf(creator) + cf.accruedTokenFees(address(usdc)), a + b);
        } else {
            vm.prank(creator);
            vm.expectRevert(Crowdfund.GoalNotReached.selector);
            cf.withdraw(id);
            uint256 aBefore = usdc.balanceOf(alice);
            uint256 bBefore = usdc.balanceOf(bob);
            vm.prank(alice);
            cf.refund(id);
            vm.prank(bob);
            cf.refund(id);
            assertEq(usdc.balanceOf(alice) - aBefore, a);
            assertEq(usdc.balanceOf(bob) - bBefore, b);
            assertEq(usdc.balanceOf(address(cf)), 0);
        }
    }
}

/// Hostile and unusual tokens.
contract CrowdfundHostileTokenTest is Test {
    Crowdfund cf;

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant GOAL = 1000 ether;
    uint256 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800);
        deadline = block.timestamp + 7 days;
    }

    function _allow(address token) internal {
        vm.prank(owner);
        cf.setTokenAllowed(token, true);
    }

    function _create(address token) internal returns (uint256 id) {
        vm.prank(creator);
        id = cf.createTokenCampaign(GOAL, deadline, 1000, token);
    }

    function _approve(address token, address who) internal {
        vm.prank(who);
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(cf), type(uint256).max));
        require(ok, "approve failed");
    }

    // ---------------------------------------------------------------- fee-on-transfer

    function test_FeeOnTransfer_IsRejectedAndNothingChanges() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        _allow(address(fot));
        fot.mint(alice, 5000 ether);
        _approve(address(fot), alice);
        uint256 id = _create(address(fot));

        vm.prank(alice);
        vm.expectRevert(Crowdfund.UnsupportedToken.selector);
        cf.pledgeToken(id, 100 ether);

        assertEq(cf.getCampaign(id).raised, 0);
        assertEq(cf.pledgeOf(id, alice), 0);
        assertEq(fot.balanceOf(alice), 5000 ether); // the whole transfer rolled back
        assertEq(fot.balanceOf(address(cf)), 0);
    }

    // ---------------------------------------------------------------- USDT-style: returns nothing

    function test_NoReturnToken_FullFlowWorks() public {
        NoReturnToken t = new NoReturnToken();
        _allow(address(t));
        t.mint(alice, 2000 ether);
        _approve(address(t), alice);
        uint256 id = _create(address(t));

        vm.prank(alice);
        cf.pledgeToken(id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        assertEq(t.balanceOf(creator), 920 ether);
        cf.claimTokenFees(address(t));
        assertEq(t.balanceOf(recipient), 80 ether);
    }

    function test_NoReturnToken_RefundWorks() public {
        NoReturnToken t = new NoReturnToken();
        _allow(address(t));
        t.mint(alice, 100 ether);
        _approve(address(t), alice);
        uint256 id = _create(address(t));
        vm.prank(alice);
        cf.pledgeToken(id, 100 ether);
        vm.warp(deadline);
        vm.prank(alice);
        cf.refund(id);
        assertEq(t.balanceOf(alice), 100 ether);
    }

    // ---------------------------------------------------------------- returns false instead of reverting

    function test_FalseReturn_PayoutFailureRevertsEverything() public {
        FalseReturnToken t = new FalseReturnToken();
        _allow(address(t));
        t.mint(alice, 2000 ether);
        _approve(address(t), alice);
        uint256 id = _create(address(t));
        vm.prank(alice);
        cf.pledgeToken(id, GOAL);
        vm.warp(deadline);

        t.setFail(true, false); // transfers now return false
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        cf.withdraw(id);
        assertFalse(cf.getCampaign(id).paidOut);
        assertEq(cf.accruedTokenFees(address(t)), 0); // the fee accrual rolled back too
        assertEq(t.balanceOf(address(cf)), GOAL);

        t.setFail(false, false);
        vm.prank(creator);
        cf.withdraw(id); // works once the token behaves
        assertEq(t.balanceOf(creator), 920 ether);
    }

    function test_FalseReturn_PledgeFailureReverts() public {
        FalseReturnToken t = new FalseReturnToken();
        _allow(address(t));
        t.mint(alice, 100 ether);
        _approve(address(t), alice);
        uint256 id = _create(address(t));
        t.setFail(false, true); // transferFrom returns false

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        cf.pledgeToken(id, 10 ether);
        assertEq(cf.getCampaign(id).raised, 0);
    }

    // ---------------------------------------------------------------- blocklist (stablecoin style)

    function test_Blocklist_ABlockedBackerOnlyBlocksTheirOwnRefund() public {
        BlocklistToken t = new BlocklistToken();
        _allow(address(t));
        t.mint(alice, 1000 ether);
        t.mint(bob, 1000 ether);
        _approve(address(t), alice);
        _approve(address(t), bob);
        uint256 id = _create(address(t));
        vm.prank(alice);
        cf.pledgeToken(id, 100 ether);
        vm.prank(bob);
        cf.pledgeToken(id, 200 ether);
        vm.warp(deadline);

        t.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, alice));
        cf.refund(id);
        assertEq(cf.pledgeOf(id, alice), 100 ether); // nothing lost, still refundable

        vm.prank(bob); // bob is unaffected
        cf.refund(id);
        assertEq(t.balanceOf(bob), 1000 ether);

        t.setBlocked(alice, false);
        vm.prank(alice);
        cf.refund(id);
        assertEq(t.balanceOf(alice), 1000 ether);
    }

    function test_Blocklist_ABlockedFeeRecipientNeverBlocksCreators() public {
        BlocklistToken t = new BlocklistToken();
        _allow(address(t));
        t.mint(alice, 2000 ether);
        _approve(address(t), alice);
        uint256 id = _create(address(t));
        vm.prank(alice);
        cf.pledgeToken(id, GOAL);
        vm.warp(deadline);

        t.setBlocked(recipient, true);
        vm.prank(creator);
        cf.withdraw(id); // the creator is still paid
        assertEq(t.balanceOf(creator), 920 ether);

        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, recipient));
        cf.claimTokenFees(address(t));
        assertEq(cf.accruedTokenFees(address(t)), 80 ether); // nothing lost

        vm.prank(owner);
        cf.setFeeRecipient(bob); // owner switches to an unblocked address
        cf.claimTokenFees(address(t));
        assertEq(t.balanceOf(bob), 80 ether);
    }

    function test_Blocklist_ABlockedCreatorOnlyBlocksTheirOwnPayout() public {
        BlocklistToken t = new BlocklistToken();
        _allow(address(t));
        t.mint(alice, 5000 ether);
        _approve(address(t), alice);
        uint256 mine = _create(address(t));
        vm.prank(bob);
        uint256 other = cf.createTokenCampaign(GOAL, deadline, 1000, address(t));
        vm.startPrank(alice);
        cf.pledgeToken(mine, GOAL);
        cf.pledgeToken(other, GOAL);
        vm.stopPrank();
        vm.warp(deadline);

        t.setBlocked(creator, true);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(BlocklistToken.Blocked.selector, creator));
        cf.withdraw(mine);
        assertFalse(cf.getCampaign(mine).paidOut);

        vm.prank(bob);
        cf.withdraw(other); // the other campaign is fine
        assertEq(t.balanceOf(bob), 920 ether);
    }

    // ---------------------------------------------------------------- hostile hooks (ERC-777 style)

    function _hookToken() internal returns (HookToken t, uint256 id) {
        t = new HookToken();
        _allow(address(t));
        t.mint(alice, 5000 ether);
        _approve(address(t), alice);
        id = _create(address(t));
    }

    function _assertHookBlocked(HookToken t) internal view {
        assertGt(t.hookCalls(), 0, "the hook never ran");
        assertFalse(t.lastHookOk(), "the hook managed to re-enter");
        assertEq(t.lastHookError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_Hook_CannotReenterDuringPledgeToken() public {
        (HookToken t, uint256 id) = _hookToken();
        t.setHook(address(cf), abi.encodeCall(Crowdfund.pledgeToken, (id, 1 ether)));
        vm.prank(alice);
        cf.pledgeToken(id, 10 ether);
        _assertHookBlocked(t);
        assertEq(cf.getCampaign(id).raised, 10 ether); // only the real pledge counted
    }

    function test_Hook_CannotReenterClaimDuringPledgeToken() public {
        (HookToken t, uint256 id) = _hookToken();
        t.setHook(address(cf), abi.encodeCall(Crowdfund.claimTokenFees, (address(t))));
        vm.prank(alice);
        cf.pledgeToken(id, 10 ether);
        _assertHookBlocked(t);
    }

    function test_Hook_CannotReenterDuringWithdraw() public {
        (HookToken t, uint256 id) = _hookToken();
        vm.prank(alice);
        cf.pledgeToken(id, GOAL);
        vm.warp(deadline);
        t.setHook(address(cf), abi.encodeCall(Crowdfund.withdraw, (id)));
        vm.prank(creator);
        cf.withdraw(id);
        _assertHookBlocked(t);
        assertEq(t.balanceOf(creator), 920 ether);
        assertEq(cf.accruedTokenFees(address(t)), 80 ether);
    }

    function test_Hook_CannotClaimFeesDuringWithdraw() public {
        (HookToken t, uint256 id) = _hookToken();
        vm.prank(alice);
        cf.pledgeToken(id, GOAL);
        vm.warp(deadline);
        t.setHook(address(cf), abi.encodeCall(Crowdfund.claimTokenFees, (address(t))));
        vm.prank(creator);
        cf.withdraw(id);
        _assertHookBlocked(t);
        assertEq(cf.accruedTokenFees(address(t)), 80 ether);
    }

    function test_Hook_CannotReenterDuringRefund() public {
        (HookToken t, uint256 id) = _hookToken();
        vm.prank(alice);
        cf.pledgeToken(id, 10 ether);
        vm.warp(deadline);
        t.setHook(address(cf), abi.encodeCall(Crowdfund.refund, (id)));
        vm.prank(alice);
        cf.refund(id);
        _assertHookBlocked(t);
        assertEq(t.balanceOf(alice), 5000 ether);
    }

    function test_Hook_CannotReenterDuringClaimTokenFees() public {
        (HookToken t, uint256 id) = _hookToken();
        vm.prank(alice);
        cf.pledgeToken(id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        t.setHook(address(cf), abi.encodeCall(Crowdfund.claimTokenFees, (address(t))));
        cf.claimTokenFees(address(t));
        _assertHookBlocked(t);
        assertEq(t.balanceOf(recipient), 80 ether); // paid exactly once
    }
}
