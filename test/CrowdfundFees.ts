import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

const DAY = 24 * 60 * 60;
const GOAL = ethers.parseEther("10");

async function deployFixture() {
  const [deployer, owner, recipient, creator, alice, bob, mallory] = await ethers.getSigners();
  const crowdfund = await ethers.deployContract("Crowdfund", [owner.address, recipient.address, 800n]);
  const now = BigInt(await networkHelpers.time.latest());
  const deadline = now + BigInt(7 * DAY);
  return { crowdfund, deployer, owner, recipient, creator, alice, bob, mallory, deadline };
}

describe("Crowdfund fees (end to end)", function () {
  it("an 8% campaign: creator gets 92%, the fee waits in the contract and anyone can send it to the recipient", async function () {
    const { crowdfund, creator, alice, bob, mallory, recipient, deadline } = await networkHelpers.loadFixture(deployFixture);

    await expect(crowdfund.connect(creator).createCampaign(GOAL, deadline, 800))
      .to.emit(crowdfund, "CampaignCreated")
      .withArgs(1n, creator.address, GOAL, deadline, 800n, ethers.ZeroAddress);

    await crowdfund.connect(alice).pledge(1n, { value: ethers.parseEther("6") });
    await crowdfund.connect(bob).pledge(1n, { value: ethers.parseEther("6") });
    await networkHelpers.time.increaseTo(deadline);

    const campaign = await crowdfund.getCampaign(1n);
    expect(campaign.feeBps).to.equal(800n);

    const tx = crowdfund.connect(creator).withdraw(1n);
    await expect(tx).to.emit(crowdfund, "Withdrawn").withArgs(1n, creator.address, ethers.parseEther("11.04"), ethers.parseEther("0.96"));
    await expect(tx).to.changeEtherBalance(ethers, creator, ethers.parseEther("11.04"));

    expect(await crowdfund.accruedFees()).to.equal(ethers.parseEther("0.96"));
    expect(await ethers.provider.getBalance(await crowdfund.getAddress())).to.equal(ethers.parseEther("0.96"));

    // a stranger triggers the claim; the money still goes to the fee recipient
    const claim = crowdfund.connect(mallory).claimFees();
    await expect(claim).to.emit(crowdfund, "FeesClaimed").withArgs(recipient.address, ethers.parseEther("0.96"));
    await expect(claim).to.changeEtherBalance(ethers, recipient, ethers.parseEther("0.96"));
    expect(await crowdfund.accruedFees()).to.equal(0n);
    await expect(crowdfund.connect(mallory).claimFees()).to.be.revertedWithCustomError(crowdfund, "NothingToClaim");
  });

  it("a failed campaign pays no fee and refunds in full", async function () {
    const { crowdfund, creator, alice, deadline } = await networkHelpers.loadFixture(deployFixture);

    await crowdfund.connect(creator).createCampaign(GOAL, deadline, 800);
    await crowdfund.connect(alice).pledge(1n, { value: ethers.parseEther("3") });
    await networkHelpers.time.increaseTo(deadline);

    await expect(crowdfund.connect(alice).refund(1n)).to.changeEtherBalance(ethers, alice, ethers.parseEther("3"));
    expect(await crowdfund.accruedFees()).to.equal(0n);
  });

  it("the owner cannot make a creator pay a higher fee than they agreed to", async function () {
    const { crowdfund, owner, creator, deadline } = await networkHelpers.loadFixture(deployFixture);

    await crowdfund.connect(owner).setFee(1000);
    await expect(crowdfund.connect(creator).createCampaign(GOAL, deadline, 800)).to.be.revertedWithCustomError(
      crowdfund,
      "FeeAboveMax",
    );
    await expect(crowdfund.connect(creator).createCampaign(GOAL, deadline, 1000)).to.emit(crowdfund, "CampaignCreated");
  });

  it("the fee cannot go above 10% and a campaign keeps the fee it was created with", async function () {
    const { crowdfund, owner, creator, alice, deadline } = await networkHelpers.loadFixture(deployFixture);

    await expect(crowdfund.connect(owner).setFee(1001)).to.be.revertedWithCustomError(crowdfund, "FeeTooHigh");

    await crowdfund.connect(creator).createCampaign(GOAL, deadline, 800); // created at 8%
    await crowdfund.connect(owner).setFee(1000);
    await crowdfund.connect(alice).pledge(1n, { value: GOAL });
    await networkHelpers.time.increaseTo(deadline);

    await expect(crowdfund.connect(creator).withdraw(1n))
      .to.emit(crowdfund, "Withdrawn")
      .withArgs(1n, creator.address, ethers.parseEther("9.2"), ethers.parseEther("0.8")); // still 8%
  });

  it("only the owner can run the admin functions, and pausing stops only new campaigns", async function () {
    const { crowdfund, owner, creator, alice, mallory, deadline } = await networkHelpers.loadFixture(deployFixture);

    await expect(crowdfund.connect(mallory).setFee(0)).to.be.revertedWithCustomError(
      crowdfund,
      "OwnableUnauthorizedAccount",
    );
    await expect(crowdfund.connect(mallory).setCreationPaused(true)).to.be.revertedWithCustomError(
      crowdfund,
      "OwnableUnauthorizedAccount",
    );

    await crowdfund.connect(creator).createCampaign(GOAL, deadline, 800);
    await expect(crowdfund.connect(owner).setCreationPaused(true))
      .to.emit(crowdfund, "CreationPausedUpdated")
      .withArgs(true);

    await expect(crowdfund.connect(creator).createCampaign(GOAL, deadline, 800)).to.be.revertedWithCustomError(
      crowdfund,
      "CreationPaused",
    );
    // existing campaigns keep working while creation is paused
    await expect(crowdfund.connect(alice).pledge(1n, { value: ethers.parseEther("1") })).to.emit(crowdfund, "Pledged");
  });

  it("ownership moves in two steps and cannot be renounced", async function () {
    const { crowdfund, owner, bob, mallory } = await networkHelpers.loadFixture(deployFixture);

    await expect(crowdfund.connect(owner).renounceOwnership()).to.be.revertedWithCustomError(
      crowdfund,
      "RenounceDisabled",
    );

    await crowdfund.connect(owner).transferOwnership(bob.address);
    expect(await crowdfund.owner()).to.equal(owner.address);
    await expect(crowdfund.connect(mallory).acceptOwnership()).to.be.revertedWithCustomError(
      crowdfund,
      "OwnableUnauthorizedAccount",
    );
    await crowdfund.connect(bob).acceptOwnership();
    expect(await crowdfund.owner()).to.equal(bob.address);
    await expect(crowdfund.connect(owner).setFee(0)).to.be.revertedWithCustomError(
      crowdfund,
      "OwnableUnauthorizedAccount",
    );
  });
});
