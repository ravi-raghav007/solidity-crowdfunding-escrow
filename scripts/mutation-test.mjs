// Mutation test for contracts/Crowdfund.sol.
// Breaks the contract in small, realistic ways (one at a time) and checks that the test suite FAILS for each.
// A mutant that survives (tests still pass) means the tests have a blind spot.
//
// Usage: node scripts/mutation-test.mjs [--invariants-only]
// With --invariants-only only the invariant tests run, which shows which breakages the fuzzer itself detects.
import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const FILE = "contracts/Crowdfund.sol";
const BACKUP = "contracts/Crowdfund.sol.orig";

const mutants = [
  ["remove nonReentrant from withdraw", "function withdraw(uint256 id) external nonReentrant {", "function withdraw(uint256 id) external {"],
  ["remove nonReentrant from refund", "function refund(uint256 id) external nonReentrant {", "function refund(uint256 id) external {"],
  ["swap NotEnded/GoalReached order in refund", "if (block.timestamp < c.deadline) revert NotEnded();\n        if (c.raised >= c.goal) revert GoalReached();", "if (c.raised >= c.goal) revert GoalReached();\n        if (block.timestamp < c.deadline) revert NotEnded();"],
  ["swap NotEnded/GoalNotReached order in withdraw", "if (block.timestamp < c.deadline) revert NotEnded();\n        if (c.raised < c.goal) revert GoalNotReached();", "if (c.raised < c.goal) revert GoalNotReached();\n        if (block.timestamp < c.deadline) revert NotEnded();"],
  ["withdraw goal check off by one (<=)", "if (c.raised < c.goal) revert GoalNotReached();", "if (c.raised <= c.goal) revert GoalNotReached();"],
  ["refund goal check off by one (>)", "if (c.raised >= c.goal) revert GoalReached();", "if (c.raised > c.goal) revert GoalReached();"],
  ["ETH pledge allowed at the deadline (>)", "if (msg.value == 0) revert ZeroAmount();\n        if (block.timestamp >= c.deadline) revert CampaignEnded();", "if (msg.value == 0) revert ZeroAmount();\n        if (block.timestamp > c.deadline) revert CampaignEnded();"],
  ["token pledge allowed at the deadline (>)", "if (amount == 0) revert ZeroAmount();\n        if (block.timestamp >= c.deadline) revert CampaignEnded();", "if (amount == 0) revert ZeroAmount();\n        if (block.timestamp > c.deadline) revert CampaignEnded();"],
  ["never mark paidOut", "c.paidOut = true;", ""],
  ["never zero the pledge before refund", "_pledges[id][msg.sender] = 0;", ""],
  ["withdraw payout uses the contract balance", "uint256 payout = c.raised - fee;", "uint256 payout = address(this).balance - fee;"],
  ["creator receives the full amount, no fee deducted", "_pay(token, msg.sender, payout)", "_pay(token, msg.sender, c.raised)"],
  ["fee rounds up instead of down", "Math.mulDiv(c.raised, c.feeBps, BPS)", "Math.mulDiv(c.raised, c.feeBps, BPS, Math.Rounding.Ceil)"],
  ["fee uses the current global fee, not the campaign snapshot", "Math.mulDiv(c.raised, c.feeBps, BPS)", "Math.mulDiv(c.raised, feeBps, BPS)"],
  ["campaign does not snapshot the fee", "uint16 fee = feeBps;", "uint16 fee = 0;"],
  ["fee cap constant off by one", "uint16 public constant MAX_FEE_BPS = 1000;", "uint16 public constant MAX_FEE_BPS = 1001;"],
  ["setFee has no cap check", "if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();", ""],
  ["constructor has no cap check", "if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();", ""],
  ["constructor accepts a zero fee recipient", "if (feeRecipient_ == address(0)) revert ZeroAddress();", ""],
  ["setFeeRecipient accepts zero", "if (newRecipient == address(0)) revert ZeroAddress();", ""],
  ["setFee open to everyone", "function setFee(uint16 newFeeBps) external onlyOwner {", "function setFee(uint16 newFeeBps) external {"],
  ["setFeeRecipient open to everyone", "function setFeeRecipient(address newRecipient) external onlyOwner {", "function setFeeRecipient(address newRecipient) external {"],
  ["setCreationPaused open to everyone", "function setCreationPaused(bool paused) external onlyOwner {", "function setCreationPaused(bool paused) external {"],
  ["pause is ignored by createCampaign", "if (creationPaused) revert CreationPaused();", ""],
  ["remove nonReentrant from claimFees", "function claimFees() external nonReentrant {", "function claimFees() external {"],
  ["claimFees does not clear accruedFees", "accruedFees = 0;", ""],
  ["withdraw does not accrue the ETH fee", "if (token == address(0)) accruedFees += fee;", "if (token == address(0)) {}"],
  ["withdraw does not accrue the token fee", "else accruedTokenFees[token] += fee;", "else {}"],
  ["claimFees pays the caller, not the recipient", "accruedFees = 0;\n        address recipient = feeRecipient;", "accruedFees = 0;\n        address recipient = msg.sender;"],
  ["claimTokenFees pays the caller, not the recipient", "address recipient = feeRecipient;\n        if (recipient == token) revert InvalidRecipient();", "address recipient = msg.sender;\n        if (recipient == token) revert InvalidRecipient();"],
  ["claimFees sends the whole balance", "uint256 amount = accruedFees;", "uint256 amount = address(this).balance;"],
  [
    "renounceOwnership is allowed",
    "function renounceOwnership() public pure override {\n        revert RenounceDisabled();\n    }",
    "function renounceOwnership() public override onlyOwner {\n        _transferOwnership(address(0));\n    }",
  ],
  ["createCampaign ignores the creator fee limit", "if (fee > maxFeeBps) revert FeeAboveMax();", ""],
  ["fee limit check off by one (>=)", "if (fee > maxFeeBps) revert FeeAboveMax();", "if (fee >= maxFeeBps) revert FeeAboveMax();"],
  ["fee limit checked before the zero-goal check", "if (goal == 0) revert ZeroGoal();", "if (feeBps > maxFeeBps) revert FeeAboveMax();\n        if (goal == 0) revert ZeroGoal();"],
  ["ETH payout failure is ignored (withdraw and refund)", "if (!_sendEth(to, amount)) revert TransferFailed();", "_sendEth(to, amount);"],
  // ---- stage 3: ERC-20 pledges ----
  ["pledgeToken accepted on an ETH campaign", "if (c.token == address(0)) revert WrongCurrency();", ""],
  ["ETH pledge accepted on a token campaign", "if (c.token != address(0)) revert WrongCurrency();", ""],
  ["exact-received check removed", "if (token.balanceOf(address(this)) != balanceBefore + amount) revert UnsupportedToken();", ""],
  ["exact-received check weakened to 'at least'", "if (token.balanceOf(address(this)) != balanceBefore + amount) revert UnsupportedToken();", "if (token.balanceOf(address(this)) < balanceBefore + amount) revert UnsupportedToken();"],
  ["allow-list not checked when creating a token campaign", "if (tokenMode && !allowedToken[token]) revert TokenNotAllowed();", ""],
  ["allow-list also checked at pledge time (disallowing traps funds)", "if (amount == 0) revert ZeroAmount();", "if (amount == 0) revert ZeroAmount();\n        if (!allowedToken[c.token]) revert TokenNotAllowed();"],
  ["createTokenCampaign ignores the allow list", "return _createCampaign(goal, deadline, maxFeeBps, token, true);", "return _createCampaign(goal, deadline, maxFeeBps, token, false);"],
  ["campaign does not store its token", "token: token", "token: address(0)"],
  ["setTokenAllowed accepts the zero address", "if (token == address(0)) revert ZeroAddress();", ""],
  ["setTokenAllowed open to everyone", "function setTokenAllowed(address token, bool allowed) external onlyOwner {", "function setTokenAllowed(address token, bool allowed) external {"],
  ["remove nonReentrant from pledgeToken", "function pledgeToken(uint256 id, uint256 amount) external nonReentrant {", "function pledgeToken(uint256 id, uint256 amount) external {"],
  ["remove nonReentrant from claimTokenFees", "function claimTokenFees(address token) external nonReentrant {", "function claimTokenFees(address token) external {"],
  ["claimTokenFees does not clear the accrued fees", "accruedTokenFees[token] = 0;", ""],
  ["token fee booked to the ETH counter", "else accruedTokenFees[token] += fee;", "else accruedFees += fee;"],
  ["ETH fee booked to the token counter", "if (token == address(0)) accruedFees += fee;", "if (token == address(0)) accruedTokenFees[token] += fee;"],
  ["token payouts are sent as ETH", "if (token == address(0)) {\n            if (!_sendEth(to, amount))", "if (true) {\n            if (!_sendEth(to, amount))"],
  ["payout uses a raw transfer instead of safeTransfer", "IERC20(token).safeTransfer(to, amount);", "IERC20(token).transfer(to, amount);"],
  ["fee claim uses a raw transfer instead of safeTransfer", "IERC20(token).safeTransfer(recipient, amount);", "IERC20(token).transfer(recipient, amount);"],
  ["pledge uses a raw transferFrom instead of safeTransferFrom", "token.safeTransferFrom(msg.sender, address(this), amount);", "token.transferFrom(msg.sender, address(this), amount);"],
  ["fee recipient may be the contract itself (setFeeRecipient)", "if (newRecipient == address(this)) revert InvalidRecipient();", ""],
  ["fee recipient may be the contract itself (constructor)", "if (feeRecipient_ == address(this)) revert InvalidRecipient();", ""],
  ["token fees can be claimed to the token contract itself", "if (recipient == token) revert InvalidRecipient();", ""],
  ["a token with no code can be allow-listed", "if (allowed && (token == address(this) || token.code.length == 0)) revert InvalidToken();", ""],
  ["the contract itself can be allow-listed as a token", "token == address(this) || token.code.length == 0", "token.code.length == 0"],
  ["disallowing also requires contract code", "if (allowed && (token", "if ((token"],
  ["pledgeToken does not add to raised", "c.raised += amount;", ""],
  ["pledgeToken ignores the deadline", "if (block.timestamp >= c.deadline) revert CampaignEnded();\n\n        IERC20 token", "IERC20 token"],
  ["claimFees send failure is ignored", "if (!_sendEth(recipient, amount)) revert TransferFailed();", "_sendEth(recipient, amount);"],
  [
    "ETH send copies the receiver return data again",
    'assembly ("memory-safe") {\n            ok := call(gas(), to, amount, 0, 0, 0, 0)\n        }',
    '(ok,) = payable(to).call{value: amount}("");',
  ],
  ["anyone can withdraw (no creator check)", "if (msg.sender != c.creator) revert NotCreator();", ""],
  ["refunded counter never updated", "c.refunded += amount;", ""],
  ["minimum duration exclusive", "deadline < block.timestamp + MIN_DURATION", "deadline <= block.timestamp + MIN_DURATION"],
  ["maximum duration exclusive", "deadline > block.timestamp + MAX_DURATION", "deadline >= block.timestamp + MAX_DURATION"],
  ["pledge does not add to raised", "c.raised += msg.value;", ""],
  ["pledge overwrites instead of adding", "_pledges[id][msg.sender] += msg.value;", "_pledges[id][msg.sender] = msg.value;"],
  ["allow zero-value pledges", "if (msg.value == 0) revert ZeroAmount();", ""],
  ["allow zero goal", "if (goal == 0) revert ZeroGoal();", ""],
  ["status Paid/Succeeded swapped", "c.paidOut ? Status.Paid : Status.Succeeded", "c.paidOut ? Status.Succeeded : Status.Paid"],
  ["campaign ids start at zero", "id = ++campaignCount;", "id = campaignCount++;"],
];

// a mutant must not be run against a contract file that is already modified
copyFileSync(FILE, BACKUP);
const original = readFileSync(BACKUP, "utf8");
let survived = 0;
let killed = 0;
let invalid = 0;

try {
  const only = process.argv.find((a) => a.startsWith("--only="))?.slice(7);
  for (const [name, from, to] of mutants) {
    if (only && !name.includes(only)) continue;
    if (original.split(from).length !== 2) {
      console.log(`SKIP     ${name} (anchor not found exactly once)`);
      invalid++;
      continue;
    }
    writeFileSync(FILE, original.replace(from, to));
    const grepArgs = process.argv.includes("--invariants-only") ? ["--grep", "invariant_"] : [];
    const r = spawnSync("npx", ["hardhat", "test", "solidity", ...grepArgs], { encoding: "utf8", shell: true, timeout: 280000 });
    const out = (r.stdout || "") + (r.stderr || "");
    if (!/passing|failing/.test(out)) {
      console.log(`INVALID  ${name} (did not compile or run)`);
      invalid++;
    } else if (r.status !== 0) {
      console.log(`killed   ${name}`);
      killed++;
    } else {
      console.log(`SURVIVED ${name}   <-- the tests did not notice`);
      survived++;
    }
  }
} finally {
  copyFileSync(BACKUP, FILE);
  spawnSync("node", ["-e", `require('fs').unlinkSync('${BACKUP}')`], { shell: true });
}

console.log(`\n${killed + survived + invalid} mutants run, ${killed} killed, ${survived} survived, ${invalid} invalid/skipped`);
process.exit(survived === 0 ? 0 : 1);
