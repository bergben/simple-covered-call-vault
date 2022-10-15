import { ethers } from "hardhat";
import chai from "chai";
import chaiAsPromised from "chai-as-promised";
import {
  CoveredCallVault__factory,
  CoveredCallVault,
  IERC20Upgradeable as IERC20,
} from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { solidity } from "ethereum-waffle";

const hre = require("hardhat");
const { time } = require("@openzeppelin/test-helpers");

chai.use(chaiAsPromised);
chai.use(solidity);
const { expect } = chai;

const wethAddress = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
const usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const wethWhale = "0x06920c9fc643de77b99cb7670a944ad31eaaa260";
const usdcWhale = "0xa7c0e546196a0bdbc2cb9743bcfbf3536b577e1e";

describe("CoveredCallVault", () => {
  const bufferTime = 86400; // 1 day
  const price = 10000000; // = 10 usdc. usdc has 6 decimals

  let weth: IERC20;
  let usdc: IERC20;
  let vault: CoveredCallVault;
  let migrationVault: CoveredCallVault;
  let startTime: number;
  let endTime: number;

  let exchange: SignerWithAddress;
  let user: SignerWithAddress;
  let owner: SignerWithAddress;

  beforeEach(async () => {
    weth = (await ethers.getContractAt("ERC20", wethAddress)) as IERC20;
    usdc = (await ethers.getContractAt("ERC20", usdcAddress)) as IERC20;

    const signers = await ethers.getSigners();
    owner = signers[2];

    // set up user with ETH and WETH
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [wethWhale],
    });
    user = await ethers.getSigner(wethWhale);
    await signers[0].sendTransaction({
      to: wethWhale,
      value: ethers.utils.parseEther("100"),
      gasLimit: 500000,
    });
    // set up exchange with ETH and USDC
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [usdcWhale],
    });
    exchange = await ethers.getSigner(usdcWhale);
    await signers[0].sendTransaction({
      to: usdcWhale,
      value: ethers.utils.parseEther("100"),
      gasLimit: 500000,
    });

    // deploy vault
    const vaultFactory = (await ethers.getContractFactory(
      "CoveredCallVault",
      owner
    )) as CoveredCallVault__factory;

    startTime = (await getCurrentBlockTime()) + 100;
    endTime = startTime + 1000;

    vault = await vaultFactory.deploy();
    await vault.deployed();

    await vault.initialize(
      wethAddress,
      "CoveredCallVaultWETH",
      "ccvWETH",
      exchange.address,
      bufferTime,
      usdcAddress,
      startTime,
      endTime,
      price
    );

    const initialAssets = await vault.totalAssets();
    const initialUsdc = await vault.totalUsdc();

    // check initial values
    expect(initialAssets).to.eq(0);
    expect(initialUsdc).to.eq(0);
    expect(vault.address).to.properAddress;
    expect(await vault.exchangeAddress()).to.equal(exchange.address);
    expect(await vault.startTime()).to.equal(startTime);
    expect(await vault.endTime()).to.equal(endTime);
    expect(await vault.bufferTime()).to.equal(bufferTime);
    expect(await vault.limitPrice()).to.equal(price);
  });

  describe("deposit", async () => {
    it("should deposit", async () => {
      expect(await vault.balanceOf(user.address)).to.equal(0);

      await weth
        .connect(user)
        .approve(vault.address, ethers.utils.parseEther("10"));

      await vault
        .connect(user)
        .deposit(ethers.utils.parseEther("10"), user.address);

      expect(await vault.balanceOf(user.address)).to.equal(
        ethers.utils.parseEther("10")
      );
    });

    it("should mint", async () => {
      expect(await vault.balanceOf(user.address)).to.equal(0);

      await weth
        .connect(user)
        .approve(vault.address, ethers.utils.parseEther("10"));

      await vault
        .connect(user)
        .mint(ethers.utils.parseEther("10"), user.address);

      expect(await vault.balanceOf(user.address)).to.equal(
        ethers.utils.parseEther("10")
      );
    });

    it("should fail deposit if block time > startTime", async () => {
      const currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < startTime) {
        await time.increase(startTime - currentBlockTime + 1);
      }

      await expect(
        vault.deposit(ethers.utils.parseEther("10"), user.address)
      ).to.be.revertedWith(`RoundAlreadyStarted`);
    });
  });

  describe("withdraw", async () => {
    beforeEach(async () => {
      await weth
        .connect(user)
        .approve(vault.address, ethers.utils.parseEther("10"));

      await vault
        .connect(user)
        .deposit(ethers.utils.parseEther("10"), user.address);
    });

    it("should fail withdrawal if block time < endTime", async () => {
      const currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < startTime) {
        await time.increase(startTime - currentBlockTime + 1);
      }

      await expect(
        vault.withdraw(
          ethers.utils.parseEther("10"),
          user.address,
          user.address
        )
      ).to.be.revertedWith(`RoundNotEnded`);
    });

    it("should withdraw", async () => {
      expect(await vault.balanceOf(user.address)).to.equal(
        ethers.utils.parseEther("10")
      );

      const currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < endTime) {
        await time.increase(endTime - currentBlockTime + 1);
      }

      await vault
        .connect(user)
        .withdraw(ethers.utils.parseEther("10"), user.address, user.address);

      expect(await vault.balanceOf(user.address)).to.equal(0);
    });

    it("should mint", async () => {
      expect(await vault.balanceOf(user.address)).to.equal(
        ethers.utils.parseEther("10")
      );

      const currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < endTime) {
        await time.increase(endTime - currentBlockTime + 1);
      }

      await vault
        .connect(user)
        .redeem(ethers.utils.parseEther("10"), user.address, user.address);

      expect(await vault.balanceOf(user.address)).to.equal(0);
    });
  });

  describe("owner actions", async () => {
    // should set buffer time
    // should set limit price
    // should pause
    // should unpause
    // etc.
  });

  describe("buyOption", async () => {
    beforeEach(async () => {
      await weth
        .connect(user)
        .approve(vault.address, ethers.utils.parseEther("10"));

      await vault
        .connect(user)
        .deposit(ethers.utils.parseEther("10"), user.address);
    });

    it("should revert if not exchange", async () => {
      await expect(
        vault.connect(user).buyOption(ethers.utils.parseEther("10"), price)
      ).to.be.revertedWith(`Unauthorized`);
    });

    it("should revert if price too low", async () => {
      await expect(
        vault
          .connect(exchange)
          .buyOption(ethers.utils.parseEther("10"), price - 100)
      ).to.be.revertedWith(`PriceTooLow`);
    });

    it("should buyOption", async () => {
      const currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < startTime) {
        await time.increase(startTime - currentBlockTime + 1);
      }

      usdc.connect(exchange).approve(vault.address, price * 10);

      const allowanceBefore = await weth.allowance(
        vault.address,
        exchange.address
      );

      await vault
        .connect(exchange)
        .buyOption(ethers.utils.parseEther("10"), price);

      const allowanceAfter = await weth.allowance(
        vault.address,
        exchange.address
      );

      expect(allowanceAfter).to.equal(
        allowanceBefore.add(price * 10).mul(1e11) // price is 6 decimals but allowance for weth is 18 decimals
      );
    });

    it("should revert if buffer time active", async () => {
      const currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < endTime) {
        await time.increase(endTime - currentBlockTime + 1);
      }

      await expect(
        vault.connect(exchange).buyOption(ethers.utils.parseEther("10"), price)
      ).to.be.revertedWith(`BufferTimeNotEnded`);
    });
  });

  describe("rollOptionsVault", async () => {
    // should test revert for each invalid param

    it("should revert if not after buffer time", async () => {
      await expect(
        vault.connect(user).rollOptionsVault(
          startTime + 5000,
          endTime + 5000,
          "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
          0 // should get actual quote
        )
      ).to.be.revertedWith(`BufferTimeNotEnded`);
    });

    it("should rollOptionsVault", async () => {
      let currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < endTime + bufferTime) {
        await time.increase(endTime + bufferTime - currentBlockTime + 1);
      }

      currentBlockTime = await getCurrentBlockTime();

      await vault.connect(user).rollOptionsVault(
        currentBlockTime + 5000,
        currentBlockTime + 5100,
        "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
        1 // should get actual quote from uniV2Router
      );

      expect(await vault.startTime()).to.equal(currentBlockTime + 5000);
      expect(await vault.endTime()).to.equal(currentBlockTime + 5100);
    });

    it("should swap in rollOptionsVault", async () => {
      // deposit weth
      await weth
        .connect(user)
        .approve(vault.address, ethers.utils.parseEther("50"));

      let currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < startTime) {
        await time.increase(startTime - currentBlockTime + 1);
      }

      // buyOption to transfer usdc
      usdc.connect(exchange).approve(vault.address, price * 10);
      await vault
        .connect(exchange)
        .buyOption(ethers.utils.parseEther("10"), price);

      const wethBalanceBefore = await weth.balanceOf(vault.address);
      expect(await usdc.balanceOf(vault.address)).to.equal(price * 10);

      // roll vault
      currentBlockTime = await getCurrentBlockTime();
      if (currentBlockTime < endTime + bufferTime) {
        await time.increase(endTime + bufferTime - currentBlockTime + 1);
      }

      currentBlockTime = await getCurrentBlockTime();

      await vault.connect(user).rollOptionsVault(
        currentBlockTime + 5000,
        currentBlockTime + 5100,
        "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",
        1 // should get actual quote from uniV2Router
      );

      expect(await usdc.balanceOf(vault.address)).to.equal(0);
      const wethBalanceAfter = await weth.balanceOf(vault.address);
      expect(wethBalanceAfter).to.be.gt(wethBalanceBefore);

      expect(await vault.startTime()).to.equal(currentBlockTime + 5000);
      expect(await vault.endTime()).to.equal(currentBlockTime + 5100);
    });
  });

  async function getCurrentBlockTime() {
    const blockN = await ethers.provider.getBlockNumber();
    return (await ethers.provider.getBlock(blockN)).timestamp;
  }
});
