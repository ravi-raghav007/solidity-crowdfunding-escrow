import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

const DAY = 24 * 60 * 60;
const GOAL = ethers.parseEther("10");

// Statuses as declared in Crowdfund.sol: Active, Succeeded, Paid, Failed
const Status = { Active: 0n, Succeeded: 1n, Paid: 2n, Failed: 3n };

async function deployFixture() {
  const [deployer, creator, alice, bob, mallory] = await ethers.getSigners();
  const crowdfund = await ethers.deployContract("Crowdfund", [deployer.address, mallory.address, 0n]);
  const now = BigInt(await networkHelpers.time.latest());
  const deadline = now + BigInt(7 * DAY);
  return { crowdfund, deployer, creator, alice, bob, mallory, deadline };
}

describe("Crowdfund (end to end)", function () {
  it("success path: backers fund, creator is paid once, events carry the right data", async function () {
    const { crowdfund, creator, alice, bob, deadline } = await networkHelpers.loadFixture(deployFixture);

    await expect(crowdfund.connect(creator).createCampaign(GOAL, deadline, 1000))
      .to.emit(crowdfund, "CampaignCreated")
      .withArgs(1n, creator.address, GOAL, deadline, 0n, ethers.ZeroAddress);

    await expect(crowdfund.connect(alice).pledge(1n, { value: ethers.parseEther("6") }))
      .to.emit(crowdfund, "Pledged")
      .withArgs(1n, alice.address, ethers.parseEther("6"));
    await crowdfund.connect(bob).pledge(1n, { value: ethers.parseEther("5") });

    expect(await crowdfund.statusOf(1n)).to.equal(Status.Active);
    expect(await ethers.provider.getBalance(await crowdfund.getAddress())).to.equal(ethers.parseEther("11"));

    // too early for the creator
    await expect(crowdfund.connect(creator).withdraw(1n)).to.be.revertedWithCustomError(crowdfund, "NotEnded");

    await networkHelpers.time.increaseTo(deadline);
    expect(await crowdfund.statusOf(1n)).to.equal(Status.Succeeded);

    // backers cannot refund a successful campaign
    await expect(crowdfund.connect(alice).refund(1n)).to.be.revertedWithCustomError(crowdfund, "GoalReached");

    await expect(crowdfund.connect(creator).withdraw(1n))
      .to.emit(crowdfund, "Withdrawn")
      .withArgs(1n, creator.address, ethers.parseEther("11"), 0n);

    expect(await crowdfund.statusOf(1n)).to.equal(Status.Paid);
    expect(await ethers.provider.getBalance(await crowdfund.getAddress())).to.equal(0n);
    await expect(crowdfund.connect(creator).withdraw(1n)).to.be.revertedWithCustomError(crowdfund, "AlreadyPaid");
  });

  it("failure path: every backer gets exactly their own pledge back and the creator gets nothing", async function () {
    const { crowdfund, creator, alice, bob, deadline } = await networkHelpers.loadFixture(deployFixture);

    await crowdfund.connect(creator).createCampaign(GOAL, deadline, 1000);
    await crowdfund.connect(alice).pledge(1n, { value: ethers.parseEther("3") });
    await crowdfund.connect(bob).pledge(1n, { value: ethers.parseEther("2") });
    await networkHelpers.time.increaseTo(deadline);

    expect(await crowdfund.statusOf(1n)).to.equal(Status.Failed);
    await expect(crowdfund.connect(creator).withdraw(1n)).to.be.revertedWithCustomError(crowdfund, "GoalNotReached");

    await expect(crowdfund.connect(alice).refund(1n)).to.changeEtherBalance(ethers, alice, ethers.parseEther("3"));
    await expect(crowdfund.connect(bob).refund(1n))
      .to.emit(crowdfund, "Refunded")
      .withArgs(1n, bob.address, ethers.parseEther("2"));

    expect(await ethers.provider.getBalance(await crowdfund.getAddress())).to.equal(0n);
    await expect(crowdfund.connect(alice).refund(1n)).to.be.revertedWithCustomError(crowdfund, "NothingToRefund");
  });

  it("a stranger cannot take anyone's money", async function () {
    const { crowdfund, creator, alice, mallory, deadline } = await networkHelpers.loadFixture(deployFixture);

    await crowdfund.connect(creator).createCampaign(GOAL, deadline, 1000);
    await crowdfund.connect(alice).pledge(1n, { value: GOAL });
    await networkHelpers.time.increaseTo(deadline);

    await expect(crowdfund.connect(mallory).withdraw(1n)).to.be.revertedWithCustomError(crowdfund, "NotCreator");
    await expect(crowdfund.connect(mallory).refund(1n)).to.be.revertedWithCustomError(crowdfund, "GoalReached");
  });

  it("rejects plain ETH transfers and zero-value pledges", async function () {
    const { crowdfund, creator, alice, deadline } = await networkHelpers.loadFixture(deployFixture);

    await expect(alice.sendTransaction({ to: await crowdfund.getAddress(), value: 1n })).to.revert(ethers);

    await crowdfund.connect(creator).createCampaign(GOAL, deadline, 1000);
    await expect(crowdfund.connect(alice).pledge(1n, { value: 0n })).to.be.revertedWithCustomError(
      crowdfund,
      "ZeroAmount",
    );
  });

  it("enforces the deadline window when creating a campaign", async function () {
    const { crowdfund, creator } = await networkHelpers.loadFixture(deployFixture);
    const now = BigInt(await networkHelpers.time.latest());

    await expect(crowdfund.connect(creator).createCampaign(0n, now + BigInt(7 * DAY), 1000)).to.be.revertedWithCustomError(
      crowdfund,
      "ZeroGoal",
    );
    await expect(crowdfund.connect(creator).createCampaign(GOAL, now + 3600n, 1000)).to.be.revertedWithCustomError(
      crowdfund,
      "InvalidDeadline",
    );
    await expect(
      crowdfund.connect(creator).createCampaign(GOAL, now + BigInt(91 * DAY), 1000),
    ).to.be.revertedWithCustomError(crowdfund, "InvalidDeadline");
  });
});
