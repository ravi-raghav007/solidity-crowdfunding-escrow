import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

/// Deploys the escrow. owner and feeRecipient default to the deploying account, the fee defaults to 8% (the contract caps it at 10%).
export default buildModule("CrowdfundEscrow", (m) => {
  const owner = m.getParameter("owner", m.getAccount(0));
  const feeRecipient = m.getParameter("feeRecipient", m.getAccount(0));
  const feeBps = m.getParameter("feeBps", 800n);
  const crowdfund = m.contract("Crowdfund", [owner, feeRecipient, feeBps]);
  return { crowdfund };
});
