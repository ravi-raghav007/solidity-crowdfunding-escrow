// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Crowdfund
/// @notice All-or-nothing crowdfunding escrow in native ETH or in allow-listed ERC-20 tokens, with a
///         capped platform fee. See docs/SPEC-01-escrow-core.md, SPEC-02-fee-and-admin.md and
///         SPEC-03-erc20-pledges.md.
/// @dev The owner earns a fee but can never move campaign funds. Funds can only go to the creator
///      (after success, minus the fee), to the backers (after failure), and fees to the fee recipient.
contract Crowdfund is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Active,
        Succeeded,
        Paid,
        Failed
    }

    struct Campaign {
        address creator;
        uint64 deadline;
        uint16 feeBps;
        bool paidOut;
        uint256 goal;
        uint256 raised;
        uint256 refunded;
        address token; // address(0) means native ETH
    }

    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 90 days;
    uint16 public constant MAX_FEE_BPS = 1000; // 10%
    uint256 public constant BPS = 10_000;

    uint256 public campaignCount;

    /// @notice Fee (in basis points) applied to campaigns created from now on.
    uint16 public feeBps;
    address public feeRecipient;
    bool public creationPaused;
    /// @notice ETH fees earned by paid-out campaigns and not yet claimed.
    uint256 public accruedFees;

    /// @notice Tokens that may be used for new campaigns.
    mapping(address token => bool) public allowedToken;
    /// @notice Token fees earned by paid-out token campaigns and not yet claimed.
    mapping(address token => uint256) public accruedTokenFees;

    mapping(uint256 id => Campaign) private _campaigns;
    mapping(uint256 id => mapping(address backer => uint256 amount)) private _pledges;

    event CampaignCreated(
        uint256 indexed id, address indexed creator, uint256 goal, uint64 deadline, uint16 feeBps, address token
    );
    event Pledged(uint256 indexed id, address indexed backer, uint256 amount);
    event Withdrawn(uint256 indexed id, address indexed creator, uint256 amount, uint256 fee);
    event Refunded(uint256 indexed id, address indexed backer, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event CreationPausedUpdated(bool paused);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event TokenAllowedUpdated(address indexed token, bool allowed);
    event TokenFeesClaimed(address indexed token, address indexed recipient, uint256 amount);

    error ZeroGoal();
    error InvalidDeadline();
    error NoSuchCampaign();
    error ZeroAmount();
    error CampaignEnded();
    error NotCreator();
    error NotEnded();
    error GoalNotReached();
    error GoalReached();
    error AlreadyPaid();
    error NothingToRefund();
    error TransferFailed();
    error FeeTooHigh();
    error FeeAboveMax();
    error ZeroAddress();
    error CreationPaused();
    error NothingToClaim();
    error RenounceDisabled();
    error TokenNotAllowed();
    error WrongCurrency();
    error UnsupportedToken();
    error InvalidRecipient();
    error InvalidToken();

    constructor(address initialOwner, address feeRecipient_, uint16 feeBps_) Ownable(initialOwner) {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(this)) revert InvalidRecipient();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        emit FeeUpdated(feeBps_);
        emit FeeRecipientUpdated(feeRecipient_);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Set the fee for campaigns created after this call. Existing campaigns keep their own fee.
    function setFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        if (newRecipient == address(this)) revert InvalidRecipient();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    /// @notice Stop (or allow) new campaigns. Never affects pledges, payouts, refunds or fee claims.
    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPausedUpdated(paused);
    }

    /// @notice Allow or disallow a token for NEW campaigns. Existing campaigns are never affected.
    /// @dev Only an address that has contract code (and is not this contract) can be allowed. This does not
    ///      prove it is a well-behaved ERC-20; listing only trusted tokens is the owner's responsibility.
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (allowed && (token == address(this) || token.code.length == 0)) revert InvalidToken();
        allowedToken[token] = allowed;
        emit TokenAllowedUpdated(token, allowed);
    }

    /// @dev Renouncing would freeze the fee settings (and a pause) forever, so it is disabled.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Send all accrued ETH fees to the fee recipient. Anyone may call; the money only goes to the recipient.
    function claimFees() external nonReentrant {
        uint256 amount = accruedFees;
        if (amount == 0) revert NothingToClaim();

        accruedFees = 0;
        address recipient = feeRecipient;

        if (!_sendEth(recipient, amount)) revert TransferFailed();

        emit FeesClaimed(recipient, amount);
    }

    /// @notice Send all accrued fees of one token to the fee recipient. Anyone may call.
    function claimTokenFees(address token) external nonReentrant {
        uint256 amount = accruedTokenFees[token];
        if (amount == 0) revert NothingToClaim();

        address recipient = feeRecipient;
        if (recipient == token) revert InvalidRecipient();
        accruedTokenFees[token] = 0;

        IERC20(token).safeTransfer(recipient, amount);

        emit TokenFeesClaimed(token, recipient, amount);
    }

    // ------------------------------------------------------------------ campaigns

    /// @notice Open a new ETH campaign. The caller becomes the creator and the current fee is locked in.
    /// @param goal Amount in wei that must be raised by the deadline.
    /// @param deadline Unix timestamp, between now + 1 day and now + 90 days (inclusive).
    /// @param maxFeeBps Highest fee the creator accepts. Reverts if the current fee is higher, so the
    ///        owner cannot raise the fee just before the campaign is created.
    function createCampaign(uint256 goal, uint256 deadline, uint16 maxFeeBps) external returns (uint256 id) {
        return _createCampaign(goal, deadline, maxFeeBps, address(0), false);
    }

    /// @notice Open a new campaign funded in an allow-listed ERC-20 token. Amounts are in the token's smallest unit.
    function createTokenCampaign(uint256 goal, uint256 deadline, uint16 maxFeeBps, address token)
        external
        returns (uint256 id)
    {
        return _createCampaign(goal, deadline, maxFeeBps, token, true);
    }

    function _createCampaign(uint256 goal, uint256 deadline, uint16 maxFeeBps, address token, bool tokenMode)
        private
        returns (uint256 id)
    {
        if (creationPaused) revert CreationPaused();
        if (goal == 0) revert ZeroGoal();
        if (
            deadline < block.timestamp + MIN_DURATION || deadline > block.timestamp + MAX_DURATION
                || deadline > type(uint64).max
        ) {
            revert InvalidDeadline();
        }
        uint16 fee = feeBps;
        if (fee > maxFeeBps) revert FeeAboveMax();
        if (tokenMode && !allowedToken[token]) revert TokenNotAllowed();

        id = ++campaignCount;
        _campaigns[id] = Campaign({
            creator: msg.sender,
            deadline: uint64(deadline),
            feeBps: fee,
            paidOut: false,
            goal: goal,
            raised: 0,
            refunded: 0,
            token: token
        });

        emit CampaignCreated(id, msg.sender, goal, uint64(deadline), fee, token);
    }

    /// @notice Pledge the sent ETH to an ETH campaign that has not ended.
    /// @dev Not nonReentrant on purpose: it makes no external call and only touches ETH-campaign state, so a hostile
    ///      token hook that calls it while pledgeToken holds the guard cannot break any accounting.
    function pledge(uint256 id) external payable {
        Campaign storage c = _campaigns[id];
        if (c.creator == address(0)) revert NoSuchCampaign();
        if (c.token != address(0)) revert WrongCurrency();
        if (msg.value == 0) revert ZeroAmount();
        if (block.timestamp >= c.deadline) revert CampaignEnded();

        c.raised += msg.value;
        _pledges[id][msg.sender] += msg.value;

        emit Pledged(id, msg.sender, msg.value);
    }

    /// @notice Pledge `amount` tokens to a token campaign that has not ended. The caller must have approved this
    ///         contract. Tokens that deliver less than `amount` (fee-on-transfer) are rejected.
    function pledgeToken(uint256 id, uint256 amount) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (c.creator == address(0)) revert NoSuchCampaign();
        if (c.token == address(0)) revert WrongCurrency();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= c.deadline) revert CampaignEnded();

        IERC20 token = IERC20(c.token);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != balanceBefore + amount) revert UnsupportedToken();

        c.raised += amount;
        _pledges[id][msg.sender] += amount;

        emit Pledged(id, msg.sender, amount);
    }

    /// @notice Creator collects everything raised minus the campaign's fee, once the deadline has passed
    ///         and the goal was reached. The fee is kept in the contract until it is claimed.
    function withdraw(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (c.creator == address(0)) revert NoSuchCampaign();
        if (msg.sender != c.creator) revert NotCreator();
        if (block.timestamp < c.deadline) revert NotEnded();
        if (c.raised < c.goal) revert GoalNotReached();
        if (c.paidOut) revert AlreadyPaid();

        c.paidOut = true;
        uint256 fee = Math.mulDiv(c.raised, c.feeBps, BPS);
        uint256 payout = c.raised - fee;
        address token = c.token;
        if (token == address(0)) accruedFees += fee;
        else accruedTokenFees[token] += fee;

        _pay(token, msg.sender, payout);

        emit Withdrawn(id, msg.sender, payout, fee);
    }

    /// @notice A backer takes back their own pledge after the deadline if the goal was not reached. No fee.
    function refund(uint256 id) external nonReentrant {
        Campaign storage c = _campaigns[id];
        if (c.creator == address(0)) revert NoSuchCampaign();
        if (block.timestamp < c.deadline) revert NotEnded();
        if (c.raised >= c.goal) revert GoalReached();

        uint256 amount = _pledges[id][msg.sender];
        if (amount == 0) revert NothingToRefund();

        _pledges[id][msg.sender] = 0;
        c.refunded += amount;

        _pay(c.token, msg.sender, amount);

        emit Refunded(id, msg.sender, amount);
    }

    /// @dev Pays ETH (token == address(0)) or tokens. A failed ETH send reverts with TransferFailed; a failed
    ///      token transfer reverts with the token's or SafeERC20's own error.
    function _pay(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            if (!_sendEth(to, amount)) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @dev Sends ETH without copying any return data from the receiver. A normal low-level call copies
    ///      whatever the receiver returns into memory, so a receiver returning megabytes could make the
    ///      call cost millions of gas (a "return bomb"). Here the return buffer has size zero.
    function _sendEth(address to, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
    }

    function getCampaign(uint256 id) external view returns (Campaign memory) {
        Campaign memory c = _campaigns[id];
        if (c.creator == address(0)) revert NoSuchCampaign();
        return c;
    }

    function pledgeOf(uint256 id, address backer) external view returns (uint256) {
        return _pledges[id][backer];
    }

    function statusOf(uint256 id) external view returns (Status) {
        Campaign storage c = _campaigns[id];
        if (c.creator == address(0)) revert NoSuchCampaign();
        if (block.timestamp < c.deadline) return Status.Active;
        if (c.raised >= c.goal) return c.paidOut ? Status.Paid : Status.Succeeded;
        return Status.Failed;
    }
}
