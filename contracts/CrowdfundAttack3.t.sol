// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Crowdfund} from "./Crowdfund.sol";
import {MockToken} from "./helpers/TestTokens.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Token whose balanceOf(holder) lies: real balance plus a phantom amount; transferFrom can be told to
/// move nothing while still growing the phantom balance.
contract LyingToken is MockToken {
    bool public lie;
    mapping(address => uint256) public phantom;

    constructor() MockToken("Liar", "LIE", 18) {}

    function setLie(bool v) external {
        lie = v;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return super.balanceOf(a) + phantom[a];
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (lie) {
            phantom[to] += value;
            return true;
        }
        return super.transferFrom(from, to, value);
    }

    // real payouts: pay from real balance, fall back to nothing (phantom is unbacked)
    function transfer(address to, uint256 value) public override returns (bool) {
        phantom[msg.sender] = phantom[msg.sender] > value ? phantom[msg.sender] - value : 0;
        return super.transfer(to, value);
    }
}

/// Token that reverts on any transfer touching `badAddr`.
contract SelectiveToken is MockToken {
    address public badAddr;

    constructor() MockToken("Selective", "SEL", 6) {}

    function setBad(address a) external {
        badAddr = a;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(badAddr == address(0) || (from != badAddr && to != badAddr), "bad");
        super._update(from, to, value);
    }
}

/// Token that re-enters Crowdfund with a list of calls (as msg.sender == this token) on every transfer.
contract HostileToken is MockToken {
    Crowdfund public cf;
    bytes[] public calls;
    bool public armed;
    bool private _in;
    bool[] public results;
    uint256 public runs;

    constructor() MockToken("Hostile", "HOS", 18) {}

    function setCf(Crowdfund c) external {
        cf = c;
    }

    function setCalls(bytes[] calldata c) external {
        delete calls;
        for (uint256 i; i < c.length; i++) {
            calls.push(c[i]);
        }
    }

    function arm(bool a) external {
        armed = a;
    }

    function doCreate(uint256 goal, uint256 dl) external returns (uint256) {
        return cf.createTokenCampaign(goal, dl, 1000, address(this));
    }

    function doPledge(uint256 id, uint256 amt) external {
        _mint(address(this), amt);
        _approve(address(this), address(cf), amt);
        cf.pledgeToken(id, amt);
    }

    function lastResults() external view returns (bool[] memory) {
        return results;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (armed && !_in && from != address(0)) {
            _in = true;
            runs++;
            delete results;
            for (uint256 i; i < calls.length; i++) {
                (bool ok,) = address(cf).call(calls[i]);
                results.push(ok);
            }
            _in = false;
        }
        super._update(from, to, value);
    }
}

/// Returns a megabyte of data from transfer and balanceOf (return bomb).
contract BombToken is MockToken {
    bool public bomb;

    constructor() MockToken("Bomb", "BMB", 18) {}

    function setBomb(bool b) external {
        bomb = b;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        super.transfer(to, v);
        if (bomb) {
            assembly {
                mstore(0, 1)
                return(0, 1000000)
            }
        }
        return true;
    }
}

contract Attack3Test is Test {
    Crowdfund cf;
    MockToken usdc;
    MockToken zero; // 0 decimals
    MockToken huge; // 77 decimals

    address owner = makeAddr("owner");
    address recipient = makeAddr("recipient");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant GOAL = 10_000e6;
    uint256 deadline;

    function setUp() public {
        vm.warp(1_000_000);
        cf = new Crowdfund(owner, recipient, 800);
        usdc = new MockToken("USDC", "USDC", 6);
        zero = new MockToken("Zero", "ZRO", 0);
        huge = new MockToken("Huge", "HUG", 77);
        vm.startPrank(owner);
        cf.setTokenAllowed(address(usdc), true);
        cf.setTokenAllowed(address(zero), true);
        cf.setTokenAllowed(address(huge), true);
        vm.stopPrank();
        address[3] memory who = [alice, bob, mallory];
        for (uint256 i; i < 3; i++) {
            _fund(usdc, who[i]);
            _fund(zero, who[i]);
            _fund(huge, who[i]);
        }
        deadline = block.timestamp + 7 days;
    }

    function _fund(MockToken t, address who) internal {
        t.mint(who, 1_000_000_000e6);
        vm.prank(who);
        t.approve(address(cf), type(uint256).max);
    }

    function _mk(address token, uint256 goal) internal returns (uint256 id) {
        vm.prank(creator);
        id = cf.createTokenCampaign(goal, deadline, 1000, token);
    }

    function _p(address who, uint256 id, uint256 amt) internal {
        vm.prank(who);
        cf.pledgeToken(id, amt);
    }

    // ------------------------------------------------------------ lying balanceOf (trust model)

    function test_Atk_LyingTokenDrainsHonestBackersOfSameToken() public {
        LyingToken liar = new LyingToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(liar), true);
        liar.mint(alice, 1000e18);
        vm.prank(alice);
        liar.approve(address(cf), type(uint256).max);

        vm.prank(creator);
        uint256 honest = cf.createTokenCampaign(5000e18, deadline, 1000, address(liar));
        _p(alice, honest, 1000e18); // real 1000

        // attacker campaign with a free phantom pledge
        vm.prank(mallory);
        uint256 evil = cf.createTokenCampaign(100e18, deadline, 1000, address(liar));
        liar.setLie(true);
        _p(mallory, evil, 100e18);
        liar.setLie(false);

        vm.warp(deadline);
        vm.prank(mallory);
        cf.withdraw(evil); // takes 92 real tokens from alice's money
        assertEq(liar.balanceOf(mallory), 92e18);
        // alice's campaign failed; contract real balance is short so refund of 1000 fails
        assertLt(liar.balanceOf(address(cf)) - liar.phantom(address(cf)), 1000e18);
    }

    // ------------------------------------------------------------ reentrancy through hostile token

    function _hostileSetup() internal returns (HostileToken h, uint256 id) {
        h = new HostileToken();
        h.setCf(cf);
        vm.prank(owner);
        cf.setTokenAllowed(address(h), true);
        id = h.doCreate(1000e18, deadline);
        h.mint(alice, 1_000_000e18);
        vm.prank(alice);
        h.approve(address(cf), type(uint256).max);
        vm.deal(address(h), 10 ether);

        bytes[] memory c = new bytes[](8);
        c[0] = abi.encodeCall(cf.withdraw, (id));
        c[1] = abi.encodeCall(cf.refund, (id));
        c[2] = abi.encodeCall(cf.pledgeToken, (id, 1));
        c[3] = abi.encodeCall(cf.claimTokenFees, (address(h)));
        c[4] = abi.encodeCall(cf.claimFees, ());
        c[5] = abi.encodeCall(cf.createTokenCampaign, (5, deadline + 1 days, 1000, address(h)));
        c[6] = abi.encodeCall(cf.pledge, (id));
        c[7] = abi.encodeCall(cf.setFeeRecipient, (address(h)));
        h.setCalls(c);
    }

    function test_Atk_HostileHookDuringPledge() public {
        (HostileToken h, uint256 id) = _hostileSetup();
        h.arm(true);
        _p(alice, id, 2000e18);
        h.arm(false);
        bool[] memory r = h.lastResults();
        assertEq(h.runs(), 1);
        for (uint256 i; i < 5; i++) {
            assertFalse(r[i], "guarded call succeeded in pledge hook");
        }
        assertFalse(r[7], "owner fn");
        assertEq(cf.getCampaign(id).raised, 2000e18);
        assertEq(cf.feeRecipient(), recipient);
        // r[5] (create) and r[6] (ETH pledge to token campaign -> WrongCurrency) must not break accounting
        assertFalse(r[6]);
    }

    function test_Atk_HostileHookDuringWithdrawAndRefund() public {
        (HostileToken h, uint256 id) = _hostileSetup();
        _p(alice, id, 2000e18);
        vm.warp(deadline);
        h.arm(true);
        // creator is the token itself, so only the token can call withdraw; do it from the token
        vm.prank(address(h));
        cf.withdraw(id);
        h.arm(false);
        bool[] memory r = h.lastResults();
        for (uint256 i; i < 5; i++) {
            assertFalse(r[i], "reentry during payout succeeded");
        }
        assertEq(h.balanceOf(address(h)), 2000e18 - 160e18);
        assertEq(cf.accruedTokenFees(address(h)), 160e18);
        assertEq(h.balanceOf(address(cf)), 160e18);
    }

    function test_Atk_HostileHookDuringRefund() public {
        (HostileToken h, uint256 id) = _hostileSetup();
        _p(alice, id, 500e18); // fails (goal 1000)
        vm.warp(deadline);
        h.arm(true);
        vm.prank(alice);
        cf.refund(id);
        h.arm(false);
        bool[] memory r = h.lastResults();
        for (uint256 i; i < 5; i++) {
            assertFalse(r[i]);
        }
        assertEq(h.balanceOf(alice), 1_000_000e18);
        assertEq(h.balanceOf(address(cf)), 0);
    }

    // ------------------------------------------------------------ fee recipient oddities

    function test_Atk_FeeRecipientIsCrowdfundStrandsFees() public {
        uint256 id = _mk(address(usdc), GOAL);
        _p(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        // Fixed after the stage 3 review: the contract can no longer be the fee recipient, so fees cannot be stranded in it.
        vm.prank(owner);
        vm.expectRevert(Crowdfund.InvalidRecipient.selector);
        cf.setFeeRecipient(address(cf));
        assertEq(cf.accruedTokenFees(address(usdc)), 800e6); // untouched
    }

    function test_Atk_FeeRecipientIsTokenItself() public {
        uint256 id = _mk(address(usdc), GOAL);
        _p(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        // Fixed after the stage 3 review: claiming a token's fees to the token contract itself reverts and keeps the accrual.
        vm.prank(owner);
        cf.setFeeRecipient(address(usdc));
        vm.expectRevert(Crowdfund.InvalidRecipient.selector);
        cf.claimTokenFees(address(usdc));
        assertEq(cf.accruedTokenFees(address(usdc)), 800e6);
        vm.prank(owner);
        cf.setFeeRecipient(bob); // the owner fixes it and the fees are paid
        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(bob) - 1_000_000_000e6, 800e6);
    }

    function test_Atk_OwnerRedirectsAccruedTokenFeesOnly() public {
        uint256 id = _mk(address(usdc), GOAL);
        _p(alice, id, GOAL);
        _p(bob, id, 1000e6);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        vm.prank(owner);
        cf.setFeeRecipient(mallory);
        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(mallory) - 1_000_000_000e6, 880e6); // only the fee
        // owner cannot touch anything else
        vm.prank(owner);
        vm.expectRevert();
        cf.claimTokenFees(address(zero));
    }

    // ------------------------------------------------------------ selective revert / blocklist

    function test_Atk_SelectiveTokenFreezesBackersWhenCreatorBlocked() public {
        SelectiveToken s = new SelectiveToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(s), true);
        s.mint(alice, 20_000e6);
        vm.prank(alice);
        s.approve(address(cf), type(uint256).max);
        uint256 id = _mk(address(s), GOAL);
        _p(alice, id, GOAL);
        vm.warp(deadline);
        s.setBad(creator);
        vm.prank(creator);
        vm.expectRevert();
        cf.withdraw(id); // creator frozen
        vm.prank(alice);
        vm.expectRevert(Crowdfund.GoalReached.selector);
        cf.refund(id); // backer cannot refund either: token-issuer-controlled freeze (known limit)
    }

    function test_Atk_BlockedFeeRecipientRecoverableByOwner() public {
        SelectiveToken s = new SelectiveToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(s), true);
        s.mint(alice, 20_000e6);
        vm.prank(alice);
        s.approve(address(cf), type(uint256).max);
        uint256 id = _mk(address(s), GOAL);
        _p(alice, id, GOAL);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        s.setBad(recipient);
        vm.expectRevert();
        cf.claimTokenFees(address(s));
        assertEq(cf.accruedTokenFees(address(s)), 800e6); // not lost
        vm.prank(owner);
        cf.setFeeRecipient(makeAddr("r2"));
        cf.claimTokenFees(address(s));
        assertEq(s.balanceOf(makeAddr("r2")), 800e6);
    }

    function test_Atk_BlockedBackerOnlyHurtsSelf() public {
        SelectiveToken s = new SelectiveToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(s), true);
        s.mint(alice, 5000e6);
        s.mint(bob, 5000e6);
        vm.prank(alice);
        s.approve(address(cf), type(uint256).max);
        vm.prank(bob);
        s.approve(address(cf), type(uint256).max);
        uint256 id = _mk(address(s), GOAL);
        _p(alice, id, 5000e6);
        _p(bob, id, 1000e6);
        vm.warp(deadline);
        s.setBad(alice);
        vm.prank(alice);
        vm.expectRevert();
        cf.refund(id);
        vm.prank(bob);
        cf.refund(id);
        assertEq(s.balanceOf(bob), 5000e6);
    }

    // ------------------------------------------------------------ allow-list manipulation

    function test_Atk_DisallowMidCampaignDoesNotTrap() public {
        uint256 id = _mk(address(usdc), GOAL);
        _p(alice, id, 3000e6);
        vm.prank(owner);
        cf.setTokenAllowed(address(usdc), false);
        _p(bob, id, 7000e6); // pledges still ok
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        cf.claimTokenFees(address(usdc));
        assertEq(usdc.balanceOf(recipient), 800e6);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.TokenNotAllowed.selector);
        cf.createTokenCampaign(GOAL, block.timestamp + 2 days, 1000, address(usdc));
    }

    function test_Atk_EoaAllowListed() public {
        // Fixed after the stage 3 review: an address without contract code cannot be allow-listed.
        address eoa = makeAddr("eoaToken");
        vm.prank(owner);
        vm.expectRevert(Crowdfund.InvalidToken.selector);
        cf.setTokenAllowed(eoa, true);
        vm.prank(creator);
        vm.expectRevert(Crowdfund.TokenNotAllowed.selector);
        cf.createTokenCampaign(GOAL, deadline, 1000, eoa);
    }

    function test_Atk_CrowdfundAsToken() public {
        // Fixed after the stage 3 review: the Crowdfund contract itself cannot be allow-listed as a token.
        vm.prank(owner);
        vm.expectRevert(Crowdfund.InvalidToken.selector);
        cf.setTokenAllowed(address(cf), true);
    }

    function test_Atk_TokenSelfdestructedAfterPledges() public {
        uint256 id = _mk(address(usdc), GOAL);
        _p(alice, id, 100e6);
        vm.etch(address(usdc), "");
        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert();
        cf.refund(id); // reverts cleanly (no silent success)
        assertEq(cf.pledgeOf(id, alice), 100e6); // state rolled back
    }

    // ------------------------------------------------------------ cross currency

    function test_Atk_CurrencyMixing() public {
        uint256 tid = _mk(address(usdc), GOAL);
        vm.prank(creator);
        uint256 eid = cf.createCampaign(1 ether, deadline, 1000);
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.WrongCurrency.selector);
        cf.pledge{value: 1 ether}(tid);
        vm.prank(alice);
        vm.expectRevert(Crowdfund.WrongCurrency.selector);
        cf.pledgeToken(eid, 1);
        // raw ETH send has no receive/fallback
        vm.prank(alice);
        (bool ok,) = address(cf).call{value: 1 ether}("");
        assertFalse(ok);
        // forced ETH via selfdestruct-like deal does not enter accounting
        vm.deal(address(cf), 3 ether);
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimFees();
        vm.expectRevert(Crowdfund.NothingToClaim.selector);
        cf.claimTokenFees(address(0));
    }

    // ------------------------------------------------------------ decimals, huge amounts, dust

    function test_Atk_ZeroDecimalDust() public {
        uint256 id = _mk(address(zero), 10);
        _p(alice, id, 10);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id); // 8% of 10 = 0 (floor)
        assertEq(zero.balanceOf(creator), 10);
        assertEq(cf.accruedTokenFees(address(zero)), 0);
        assertEq(zero.balanceOf(address(cf)), 0);
    }

    function test_Atk_HugeAmountsNoOverflowInFee() public {
        uint256 big = (type(uint256).max - 4e15) / 2;
        address a2 = makeAddr("a2");
        address b2 = makeAddr("b2");
        huge.mint(a2, big);
        huge.mint(b2, big);
        vm.prank(a2);
        huge.approve(address(cf), type(uint256).max);
        vm.prank(b2);
        huge.approve(address(cf), type(uint256).max);
        uint256 id = _mk(address(huge), 1);
        _p(a2, id, big);
        _p(b2, id, big); // raised = 2*big = max-1
        // another pledge overflows raised and reverts, nobody else harmed
        huge.mint(mallory, 10);
        vm.warp(deadline);
        vm.prank(creator);
        cf.withdraw(id);
        uint256 raised = cf.getCampaign(id).raised;
        uint256 fee = cf.accruedTokenFees(address(huge));
        assertEq(huge.balanceOf(creator) + fee, raised);
    }

    // ------------------------------------------------------------ griefing: return bomb

    function test_Atk_ReturnBombToken() public {
        BombToken b = new BombToken();
        vm.prank(owner);
        cf.setTokenAllowed(address(b), true);
        b.mint(alice, 20_000e18);
        vm.prank(alice);
        b.approve(address(cf), type(uint256).max);
        uint256 id = _mk(address(b), 100e18);
        _p(alice, id, 100e18);
        vm.warp(deadline);
        b.setBomb(true);
        uint256 g = gasleft();
        vm.prank(creator);
        cf.withdraw(id);
        uint256 used = g - gasleft();
        emit log_named_uint("withdraw gas with 1MB return bomb", used);
        g = gasleft();
        cf.claimTokenFees(address(b));
        used = g - gasleft();
        emit log_named_uint("claimTokenFees gas with 1MB return bomb", used);
    }

    // ------------------------------------------------------------ stateful solvency fuzz

    MockToken[] toks;
    address[3] actors;

    function _owed(address token) internal view returns (uint256 owed) {
        uint256 n = cf.campaignCount();
        for (uint256 i = 1; i <= n; i++) {
            Crowdfund.Campaign memory c = cf.getCampaign(i);
            if (c.token != token) continue;
            Crowdfund.Status s = cf.statusOf(i);
            if (s == Crowdfund.Status.Paid) continue;
            if (s == Crowdfund.Status.Failed) owed += c.raised - c.refunded;
            else owed += c.raised;
        }
    }

    function _checkSolvency() internal view {
        for (uint256 i; i < toks.length; i++) {
            address t = address(toks[i]);
            assertEq(toks[i].balanceOf(address(cf)), cf.accruedTokenFees(t) + _owed(t), "token conservation");
        }
        assertEq(address(cf).balance, cf.accruedFees() + _owed(address(0)), "eth conservation");
    }

    function testFuzz_Atk_Solvency(uint256 seed) public {
        toks.push(usdc);
        toks.push(zero);
        toks.push(huge);
        actors = [alice, bob, mallory];
        for (uint256 i; i < 3; i++) {
            vm.deal(actors[i], 1000 ether);
        }
        // seed campaigns
        vm.startPrank(creator);
        cf.createCampaign(5 ether, deadline, 1000);
        cf.createTokenCampaign(3000e6, deadline, 1000, address(usdc));
        cf.createTokenCampaign(7, deadline + 1 days, 1000, address(zero));
        cf.createTokenCampaign(1e30, deadline + 2 days, 1000, address(huge));
        vm.stopPrank();

        for (uint256 step; step < 40; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 act = seed % 11;
            uint256 r = (seed >> 8);
            address who = actors[r % 3];
            uint256 id = 1 + ((r >> 4) % cf.campaignCount());
            Crowdfund.Campaign memory c = cf.getCampaign(id);
            vm.startPrank(who);
            if (act <= 2) {
                if (c.token == address(0)) {
                    try cf.pledge{value: 1 + ((r >> 16) % 3 ether)}(id) {} catch {}
                } else {
                    try cf.pledgeToken(id, 1 + ((r >> 16) % (c.token == address(huge) ? 1e29 : 2000e6))) {} catch {}
                }
            } else if (act == 3) {
                vm.warp(block.timestamp + ((r >> 20) % 3 days));
            } else if (act == 4) {
                vm.stopPrank();
                vm.prank(creator);
                try cf.withdraw(id) {} catch {}
                vm.startPrank(who);
            } else if (act == 5) {
                try cf.refund(id) {} catch {}
            } else if (act == 6) {
                try cf.claimFees() {} catch {}
            } else if (act == 7) {
                try cf.claimTokenFees(address(toks[r % 3])) {} catch {}
            } else if (act == 8) {
                vm.stopPrank();
                vm.prank(owner);
                cf.setFee(uint16((r >> 24) % 1001));
                vm.startPrank(who);
            } else if (act == 9) {
                vm.stopPrank();
                vm.prank(owner);
                cf.setFeeRecipient(actors[(r >> 30) % 3]);
                vm.startPrank(who);
            } else {
                if ((r >> 40) % 2 == 0) {
                    try cf.createCampaign(1 ether, block.timestamp + 2 days, 1000) {} catch {}
                } else {
                    try cf.createTokenCampaign(1000e6, block.timestamp + 2 days, 1000, address(toks[r % 3])) {} catch {}
                }
            }
            vm.stopPrank();
            _checkSolvency();
        }
    }
}
