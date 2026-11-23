import { expect } from "chai";
import { network } from "hardhat";

const { ethers, networkHelpers } = await network.create();

const DAY = 24 * 60 * 60;
const USDC = (n: number | string) => ethers.parseUnits(String(n), 6);
const GOAL = USDC(10_000);

async function deployFixture() {
  const [deployer, owner, recipient, creator, alice, bob, mallory] = await ethers.getSigners();
  const crowdfund = await ethers.deployContract("Crowdfund", [owner.address, recipient.address, 800n]);
  const usdc = await ethers.deployContract("MockToken", ["USD Coin", "USDC", 6]);
  await crowdfund.connect(owner).setTokenAllowed(await usdc.getAddress(), true);

  for (const who of [alice, bob]) {
    await usdc.mint(who.address, USDC(1_000_000));
    await usdc.connect(who).approve(await crowdfund.getAddress(), ethers.MaxUint256);
  }
  const now = BigInt(await networkHelpers.time.latest());
  const deadline = now + BigInt(7 * DAY);
  return { crowdfund, usdc, deployer, owner, recipient, creator, alice, bob, mallory, deadline };
}

describe("Crowdfund with ERC-20 tokens (end to end)", function () {
  it("a USDC campaign: pledge, goal reached, creator paid 92%, fee claimed by anyone", async function () {
    const { crowdfund, usdc, creator, alice, bob, mallory, recipient, deadline } =
      await networkHelpers.loadFixture(deployFixture);
    const token = await usdc.getAddress();

    await expect(crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, token))
      .to.emit(crowdfund, "CampaignCreated")
      .withArgs(1n, creator.address, GOAL, deadline, 800n, token);
    expect((await crowdfund.getCampaign(1n)).token).to.equal(token);

    await expect(crowdfund.connect(alice).pledgeToken(1n, USDC(6000)))
      .to.emit(crowdfund, "Pledged")
      .withArgs(1n, alice.address, USDC(6000));
    await crowdfund.connect(bob).pledgeToken(1n, USDC(6000));
    expect(await usdc.balanceOf(await crowdfund.getAddress())).to.equal(USDC(12_000));

    await networkHelpers.time.increaseTo(deadline);

    const tx = crowdfund.connect(creator).withdraw(1n);
    await expect(tx).to.emit(crowdfund, "Withdrawn").withArgs(1n, creator.address, USDC(11_040), USDC(960));
    await expect(tx).to.changeTokenBalance(ethers, usdc, creator, USDC(11_040));
    expect(await crowdfund.accruedTokenFees(token)).to.equal(USDC(960));
    expect(await crowdfund.accruedFees()).to.equal(0n); // the ETH fee counter is untouched

    const claim = crowdfund.connect(mallory).claimTokenFees(token);
    await expect(claim).to.emit(crowdfund, "TokenFeesClaimed").withArgs(token, recipient.address, USDC(960));
    await expect(claim).to.changeTokenBalance(ethers, usdc, recipient, USDC(960));
    await expect(crowdfund.connect(mallory).claimTokenFees(token)).to.be.revertedWithCustomError(
      crowdfund,
      "NothingToClaim",
    );
  });

  it("a failed token campaign refunds every backer in full with no fee", async function () {
    const { crowdfund, usdc, creator, alice, bob, deadline } = await networkHelpers.loadFixture(deployFixture);

    await crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, await usdc.getAddress());
    await crowdfund.connect(alice).pledgeToken(1n, USDC(3000));
    await crowdfund.connect(bob).pledgeToken(1n, USDC(2000));
    await networkHelpers.time.increaseTo(deadline);

    await expect(crowdfund.connect(alice).refund(1n)).to.changeTokenBalance(ethers, usdc, alice, USDC(3000));
    await expect(crowdfund.connect(bob).refund(1n))
      .to.emit(crowdfund, "Refunded")
      .withArgs(1n, bob.address, USDC(2000));
    expect(await usdc.balanceOf(await crowdfund.getAddress())).to.equal(0n);
    expect(await crowdfund.accruedTokenFees(await usdc.getAddress())).to.equal(0n);
  });

  it("ETH and token campaigns cannot be mixed up", async function () {
    const { crowdfund, usdc, creator, alice, deadline } = await networkHelpers.loadFixture(deployFixture);

    await crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, await usdc.getAddress()); // id 1
    await crowdfund.connect(creator).createCampaign(ethers.parseEther("1"), deadline, 800); // id 2

    await expect(crowdfund.connect(alice).pledge(1n, { value: 1n })).to.be.revertedWithCustomError(
      crowdfund,
      "WrongCurrency",
    );
    await expect(crowdfund.connect(alice).pledgeToken(2n, USDC(1))).to.be.revertedWithCustomError(
      crowdfund,
      "WrongCurrency",
    );
  });

  it("only the owner decides which tokens are allowed, and a token must be allowed to start a campaign", async function () {
    const { crowdfund, owner, creator, mallory, deadline } = await networkHelpers.loadFixture(deployFixture);
    const other = await ethers.deployContract("MockToken", ["Other", "OTH", 18]);
    const otherAddress = await other.getAddress();

    await expect(crowdfund.connect(mallory).setTokenAllowed(otherAddress, true)).to.be.revertedWithCustomError(
      crowdfund,
      "OwnableUnauthorizedAccount",
    );
    await expect(
      crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, otherAddress),
    ).to.be.revertedWithCustomError(crowdfund, "TokenNotAllowed");

    await expect(crowdfund.connect(owner).setTokenAllowed(otherAddress, true))
      .to.emit(crowdfund, "TokenAllowedUpdated")
      .withArgs(otherAddress, true);
    await expect(crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, otherAddress)).to.emit(
      crowdfund,
      "CampaignCreated",
    );
  });

  it("disallowing a token never traps an existing campaign", async function () {
    const { crowdfund, usdc, owner, creator, alice, deadline } = await networkHelpers.loadFixture(deployFixture);
    const token = await usdc.getAddress();

    await crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, token);
    await crowdfund.connect(alice).pledgeToken(1n, USDC(5000));
    await crowdfund.connect(owner).setTokenAllowed(token, false);

    await expect(crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, token)).to.be.revertedWithCustomError(
      crowdfund,
      "TokenNotAllowed",
    );
    await expect(crowdfund.connect(alice).pledgeToken(1n, USDC(5000))).to.emit(crowdfund, "Pledged");
    await networkHelpers.time.increaseTo(deadline);
    await expect(crowdfund.connect(creator).withdraw(1n)).to.changeTokenBalance(ethers, usdc, creator, USDC(9200));
  });

  it("a token that takes a cut on transfer is rejected and nothing changes", async function () {
    const { crowdfund, owner, creator, alice, deadline } = await networkHelpers.loadFixture(deployFixture);
    const fot = await ethers.deployContract("FeeOnTransferToken");
    const fotAddress = await fot.getAddress();
    await crowdfund.connect(owner).setTokenAllowed(fotAddress, true);
    await fot.mint(alice.address, ethers.parseEther("1000"));
    await fot.connect(alice).approve(await crowdfund.getAddress(), ethers.MaxUint256);

    await crowdfund.connect(creator).createTokenCampaign(ethers.parseEther("500"), deadline, 800, fotAddress);
    await expect(crowdfund.connect(alice).pledgeToken(1n, ethers.parseEther("100"))).to.be.revertedWithCustomError(
      crowdfund,
      "UnsupportedToken",
    );
    expect((await crowdfund.getCampaign(1n)).raised).to.equal(0n);
    expect(await fot.balanceOf(alice.address)).to.equal(ethers.parseEther("1000"));
  });

  it("a token pledge needs an approval and a balance", async function () {
    const { crowdfund, usdc, creator, mallory, deadline } = await networkHelpers.loadFixture(deployFixture);
    await crowdfund.connect(creator).createTokenCampaign(GOAL, deadline, 800, await usdc.getAddress());
    await expect(crowdfund.connect(mallory).pledgeToken(1n, USDC(1))).to.revert(ethers);
    await expect(crowdfund.connect(mallory).pledgeToken(1n, 0n)).to.be.revertedWithCustomError(crowdfund, "ZeroAmount");
  });
});
