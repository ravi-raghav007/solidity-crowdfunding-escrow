// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Test helpers only. None of these are meant for production.

/// A normal ERC-20 with a configurable number of decimals and a public mint.
contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Takes 1% of every transfer (burned), so the receiver gets less than the amount sent.
contract FeeOnTransferToken is MockToken {
    constructor() MockToken("Fee Token", "FEE", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 cut = value / 100;
            super._update(from, to, value - cut);
            super._update(from, address(0), cut);
        } else {
            super._update(from, to, value);
        }
    }
}

/// Like USDT: transfer, transferFrom and approve return nothing at all.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Returns false instead of reverting when told to fail.
contract FalseReturnToken is MockToken {
    bool public failTransfer;
    bool public failTransferFrom;

    constructor() MockToken("False Token", "FALSE", 18) {}

    function setFail(bool transferFails, bool transferFromFails) external {
        failTransfer = transferFails;
        failTransferFrom = transferFromFails;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (failTransfer) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (failTransferFrom) return false;
        return super.transferFrom(from, to, value);
    }
}

/// Delivers a different amount than was sent: delta > 0 means the receiver gets that many extra units (minted),
/// delta < 0 means the receiver gets that many fewer (burned). Used to test the exact-received check both ways.
contract MisdeliveringToken is MockToken {
    int256 public delta;

    constructor() MockToken("Misdelivering Token", "MIS", 18) {}

    function setDelta(int256 d) external {
        delta = d;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && delta != 0) {
            if (delta > 0) _mint(to, uint256(delta));
            else _burn(to, uint256(-delta));
        }
    }
}

/// Like a stablecoin with a blacklist: blocked addresses can neither send nor receive.
contract BlocklistToken is MockToken {
    mapping(address => bool) public blocked;

    error Blocked(address who);

    constructor() MockToken("Blocklist Token", "BLK", 6) {}

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}

/// Like an ERC-777 style token: on every transfer it first calls back into a chosen target with chosen
/// calldata (a hostile hook), and records whether that call worked and how it failed.
contract HookToken is MockToken {
    address public hookTarget;
    bytes public hookData;
    bool private _inHook;
    uint256 public hookCalls;
    bool public lastHookOk;
    bytes4 public lastHookError;

    constructor() MockToken("Hook Token", "HOOK", 18) {}

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (hookTarget != address(0) && !_inHook && from != address(0)) {
            _inHook = true;
            hookCalls++;
            (bool ok, bytes memory ret) = hookTarget.call(hookData);
            lastHookOk = ok;
            bytes4 sel;
            if (!ok && ret.length >= 4) {
                assembly {
                    sel := mload(add(ret, 32))
                }
            }
            lastHookError = sel;
            _inHook = false;
        }
        super._update(from, to, value);
    }
}
