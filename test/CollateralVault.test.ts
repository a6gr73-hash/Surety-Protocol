import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { Surety, CollateralVault, MockUSDC } from "../typechain-types";

describe("CollateralVault Staking", function () {
    let suretyToken: Surety;
    let mockUsdc: MockUSDC;
    let vault: CollateralVault;
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;
    let addr2: SignerWithAddress;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();

        const SuretyFactory = await ethers.getContractFactory("Surety");
        suretyToken = await SuretyFactory.deploy();
        await suretyToken.waitForDeployment();

        const MockUsdcFactory = await ethers.getContractFactory("MockUSDC");
        mockUsdc = await MockUsdcFactory.deploy();
        await mockUsdc.waitForDeployment();

        const VaultFactory = await ethers.getContractFactory("CollateralVault");
        vault = await VaultFactory.deploy(await suretyToken.getAddress(), await mockUsdc.getAddress());
        await vault.waitForDeployment();

        await suretyToken.connect(owner).transfer(addr1.address, ethers.parseEther("1000"));
    });

    describe("Basic Deposit and Withdraw", function () {
        it("Should deploy the vault with the correct token addresses", async function () {
            expect(await vault.srt()).to.equal(await suretyToken.getAddress());
            expect(await vault.usdc()).to.equal(await mockUsdc.getAddress());
        });

        it("Should allow a user to deposit tokens and update free stake", async function () {
            const depositAmount = ethers.parseEther("500");
            await suretyToken.connect(addr1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);
            
            expect(await vault.srtFreeOf(addr1.address)).to.equal(depositAmount);
        });

        it("Should emit a DepositedSRT event on successful deposit", async function () {
            const depositAmount = ethers.parseEther("100");
            await suretyToken.connect(addr1).approve(await vault.getAddress(), depositAmount);

            await expect(vault.connect(addr1).depositSRT(depositAmount))
                .to.emit(vault, "DepositedSRT")
                .withArgs(addr1.address, depositAmount);
        });

        it("Should reject a deposit of 0 tokens", async function () {
            await expect(vault.connect(addr1).depositSRT(0)).to.be.revertedWith("amount=0");
        });

        it("Should allow a user to withdraw their free stake", async function () {
            const depositAmount = ethers.parseEther("400");
            const withdrawAmount = ethers.parseEther("150");

            await suretyToken.connect(addr1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);
            await vault.connect(addr1).withdrawSRT(withdrawAmount);
            
            expect(await vault.srtFreeOf(addr1.address)).to.equal(depositAmount - withdrawAmount);
        });

        it("Should reject withdrawing more than the available free stake", async function () {
            const depositAmount = ethers.parseEther("200");
            await suretyToken.connect(addr1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);

            const overdrawAmount = ethers.parseEther("201");
            await expect(vault.connect(addr1).withdrawSRT(overdrawAmount))
                .to.be.revertedWith("insufficient SRT");
        });
    });

    describe("Locking, Releasing, and Slashing Logic", function () {
        let settlementContract: SignerWithAddress;

        beforeEach(async function () {
            settlementContract = addr2;
            await vault.connect(owner).setSettlementContract(settlementContract.address);

            const depositAmount = ethers.parseEther("500");
            await suretyToken.connect(addr1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);
        });

        it("Should allow the authorized settlement contract to lock a user's stake", async function () {
            const lockAmount = ethers.parseEther("300");
            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);
            
            expect(await vault.srtFreeOf(addr1.address)).to.equal(ethers.parseEther("200"));
            expect(await vault.srtLockedOf(addr1.address)).to.equal(lockAmount);
        });

        it("Should reject lock attempts from non-authorized addresses", async function () {
            const lockAmount = ethers.parseEther("300");
            await expect(vault.connect(addr1).lockSRT(addr1.address, lockAmount))
                .to.be.revertedWith("not settlement");
        });

        it("Should prevent a user from withdrawing funds that are locked", async function () {
            const lockAmount = ethers.parseEther("400");
            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);
            
            await expect(vault.connect(addr1).withdrawSRT(ethers.parseEther("101")))
                .to.be.revertedWith("insufficient SRT");
        });

        it("Should allow the settlement contract to release a locked stake", async function () {
            const lockAmount = ethers.parseEther("400");
            const releaseAmount = ethers.parseEther("150");
            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);
            await vault.connect(settlementContract).releaseSRT(addr1.address, releaseAmount);
            
            expect(await vault.srtFreeOf(addr1.address)).to.equal(ethers.parseEther("250"));
            expect(await vault.srtLockedOf(addr1.address)).to.equal(ethers.parseEther("250"));
        });

        it("Should allow the settlement contract to slash a locked stake", async function () {
            const lockAmount = ethers.parseEther("350");
            const slashAmount = ethers.parseEther("200");
            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);
            
            const recipientBalanceBefore = await suretyToken.balanceOf(settlementContract.address);
            await vault.connect(settlementContract).slashSRT(addr1.address, slashAmount, settlementContract.address);
            const recipientBalanceAfter = await suretyToken.balanceOf(settlementContract.address);

            expect(await vault.srtLockedOf(addr1.address)).to.equal(ethers.parseEther("150"));
            expect(recipientBalanceAfter).to.equal(recipientBalanceBefore + slashAmount);
        });
    });
});