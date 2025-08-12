import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { Surety, MockOracle } from "../typechain-types";

describe("Surety Token Staking", function () {
    let suretyToken: Surety;
    let mockOracle: MockOracle;
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;
    let addr2: SignerWithAddress;

    // The oracle price of 1 SRT in USD, with 8 decimals
    const initialSrtPrice = ethers.parseUnits("1", 8); // $1.00

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();

        // Deploy the MockOracle first
        const MockOracleFactory = await ethers.getContractFactory("MockOracle");
        mockOracle = await MockOracleFactory.deploy(initialSrtPrice);
        await mockOracle.waitForDeployment();
        
        // Deploy the Surety contract with the MockOracle's address
        const SuretyFactory = await ethers.getContractFactory("Surety");
        suretyToken = await SuretyFactory.deploy(mockOracle.target);
        await suretyToken.waitForDeployment();
    });

    it("Should deploy the contract with the correct oracle address", async function () {
        // This is the correct way to call the getter function
        expect(await suretyToken.oracle()).to.equal(mockOracle.target);
    });

    it("Should allow a user to stake tokens and update the staked balance", async function () {
        // Owner transfers some tokens to addr1 to have something to stake
        const initialTransferAmount = ethers.parseEther("1000"); // 1000 SRT
        await suretyToken.transfer(addr1.address, initialTransferAmount);
        
        // Check initial balance and staked balance of addr1
        expect(await suretyToken.balanceOf(addr1.address)).to.equal(initialTransferAmount);
        expect(await suretyToken.stakedBalances(addr1.address)).to.equal(0);
        
        // Addr1 stakes 500 tokens
        const stakeAmount = ethers.parseEther("500"); // 500 SRT
        await suretyToken.connect(addr1).stake(stakeAmount);
        
        // Check new balances
        expect(await suretyToken.balanceOf(addr1.address)).to.equal(initialTransferAmount - stakeAmount);
        expect(await suretyToken.stakedBalances(addr1.address)).to.equal(stakeAmount);
    });

    it("Should not allow a user to stake more tokens than they own", async function () {
        const initialTransferAmount = ethers.parseEther("100");
        await suretyToken.transfer(addr1.address, initialTransferAmount);

        const stakeAmount = ethers.parseEther("200");
        
        // Expect the transaction to be reverted with a custom error
        await expect(suretyToken.connect(addr1).stake(stakeAmount)).to.be.revertedWithCustomError(
            suretyToken, 
            "ERC20InsufficientBalance"
        );
    });

    it("Should allow a user to unstake tokens and update the balances", async function () {
        // Owner transfers some tokens to addr1 and addr1 stakes them
        const initialTransferAmount = ethers.parseEther("1000");
        await suretyToken.transfer(addr1.address, initialTransferAmount);
        await suretyToken.connect(addr1).stake(ethers.parseEther("500"));

        // Check balances before unstaking
        expect(await suretyToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("500"));
        expect(await suretyToken.stakedBalances(addr1.address)).to.equal(ethers.parseEther("500"));

        // Addr1 unstakes 200 tokens
        const unstakeAmount = ethers.parseEther("200");
        await suretyToken.connect(addr1).unstake(unstakeAmount);

        // Check balances after unstaking
        expect(await suretyToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("700"));
        expect(await suretyToken.stakedBalances(addr1.address)).to.equal(ethers.parseEther("300"));
    });

    it("Should not allow a user to unstake more tokens than they have staked", async function () {
        // Owner transfers some tokens to addr1 and addr1 stakes them
        const initialTransferAmount = ethers.parseEther("1000");
        await suretyToken.transfer(addr1.address, initialTransferAmount);
        await suretyToken.connect(addr1).stake(ethers.parseEther("500"));
        
        // Addr1 tries to unstake 600 tokens, which is more than their staked balance
        const unstakeAmount = ethers.parseEther("600");
        await expect(suretyToken.connect(addr1).unstake(unstakeAmount)).to.be.revertedWith(
            "Insufficient staked balance"
        );
    });
});