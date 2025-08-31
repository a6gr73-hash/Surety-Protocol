import { expect } from "chai";
import { ethers } from "hardhat";
import type { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import type { Surety, CollateralVault, MockERC20 } from "../typechain-types";

describe("CollateralVault Staking", function () {
    let suretyToken: Surety;
    let mockUsdc: MockERC20;
    let vault: CollateralVault;
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;
    let addr2: SignerWithAddress;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();

        const SuretyFactory = await ethers.getContractFactory("Surety");
        const initialSupply = ethers.parseEther("1000000");
        suretyToken = (await SuretyFactory.deploy(initialSupply)) as unknown as Surety;
        await suretyToken.waitForDeployment();

        // Deploy Mock USDC
        const MockUsdcFactory = await ethers.getContractFactory("MockERC20");
        mockUsdc = (await MockUsdcFactory.deploy("Mock USDC", "mUSDC")) as unknown as MockERC20;
        await mockUsdc.waitForDeployment();

        // Deploy CollateralVault
        const VaultFactory = await ethers.getContractFactory("CollateralVault");
        vault = (await VaultFactory.deploy(await suretyToken.getAddress(), await mockUsdc.getAddress())) as unknown as CollateralVault;
        await vault.waitForDeployment();
        // Transfer some SRT to addr1 for testing
        await suretyToken.transfer(addr1.address, ethers.parseEther("1000"));
    });

    describe("Basic Deposit and Withdraw", function () {
        it("Should deploy the vault with the correct token address", async function () {
            expect(await vault.SRT()).to.equal(await suretyToken.getAddress());
        });

        it("Should allow a user to deposit tokens and update unlocked stake", async function () {
            const depositAmount = ethers.parseEther("500");

            await suretyToken.connect(addr1).approve(vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);

            expect(await suretyToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("500"));
            expect(await vault.srtStake(addr1.address)).to.equal(depositAmount);
        });

        it("Should emit a Deposited event on successful deposit", async function () {
            const depositAmount = ethers.parseEther("100");
            await suretyToken.connect(addr1).approve(vault.getAddress(), depositAmount);

            await expect(vault.connect(addr1).depositSRT(depositAmount))
                .to.emit(vault, "DepositedSRT")
                .withArgs(addr1.address, depositAmount);
        });

        it("Should reject a deposit of 0 tokens", async function () {
            await expect(vault.connect(addr1).depositSRT(0)).to.be.revertedWith("amount=0");
        });

        it("Should allow a user to withdraw their unlocked stake", async function () {
            const depositAmount = ethers.parseEther("400");
            const withdrawAmount = ethers.parseEther("150");

            await suretyToken.connect(addr1).approve(vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);
            await vault.connect(addr1).withdrawSRT(withdrawAmount);

            expect(await suretyToken.balanceOf(addr1.address)).to.equal(ethers.parseEther("750"));
            expect(await vault.srtStake(addr1.address)).to.equal(ethers.parseEther("250"));
        });

        it("Should reject withdrawing more than the available unlocked stake", async function () {
            const depositAmount = ethers.parseEther("200");
            await suretyToken.connect(addr1).approve(vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);

            const overdrawAmount = ethers.parseEther("201");
            await expect(vault.connect(addr1).withdrawSRT(overdrawAmount)).to.be.revertedWith("insufficient SRT");
        });
    });

    describe("Locking, Releasing, and Slashing Logic", function () {
        let settlementContract: SignerWithAddress;

        beforeEach(async function () {
            settlementContract = addr2;

            await vault.connect(owner).setSettlementContract(settlementContract.address);

            const depositAmount = ethers.parseEther("500");
            await suretyToken.connect(addr1).approve(vault.getAddress(), depositAmount);
            await vault.connect(addr1).depositSRT(depositAmount);
        });

        it("Should allow the authorized settlement contract to lock a user's stake", async function () {
            const lockAmount = ethers.parseEther("300");

            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);
            expect(await vault.srtStake(addr1.address)).to.equal(ethers.parseEther("200"));
            expect(await vault.srtLocked(addr1.address)).to.equal(lockAmount);
        });

        it("Should reject lock attempts from non-authorized addresses", async function () {
            const lockAmount = ethers.parseEther("300");

            await expect(vault.connect(addr1).lockSRT(addr1.address, lockAmount))
                .to.be.revertedWith("not settlement");
        });

        it("Should prevent a user from withdrawing funds that are locked", async function () {
            const lockAmount = ethers.parseEther("400");
            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);

            await expect(vault.connect(addr1).withdrawSRT(ethers.parseEther("101"))).to.be.revertedWith("insufficient SRT");
            await expect(vault.connect(addr1).withdrawSRT(ethers.parseEther("100"))).to.not.be.reverted;

            expect(await vault.srtStake(addr1.address)).to.equal(0);
        });

        it("Should allow the settlement contract to release a locked stake", async function () {
            const lockAmount = ethers.parseEther("400");
            const releaseAmount = ethers.parseEther("150");

            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);

            expect(await vault.srtStake(addr1.address)).to.equal(ethers.parseEther("100"));
            expect(await vault.srtLocked(addr1.address)).to.equal(lockAmount);

            await vault.connect(settlementContract).releaseSRT(addr1.address, releaseAmount);

            expect(await vault.srtStake(addr1.address)).to.equal(ethers.parseEther("250"));
            expect(await vault.srtLocked(addr1.address)).to.equal(ethers.parseEther("250"));
        });

        it("Should allow the settlement contract to slash a locked stake", async function () {
            const lockAmount = ethers.parseEther("350");
            const slashAmount = ethers.parseEther("200");

            await vault.connect(settlementContract).lockSRT(addr1.address, lockAmount);

            const settlementBalanceBefore = await suretyToken.balanceOf(settlementContract.address);

            await vault.connect(settlementContract).slashSRT(addr1.address, slashAmount, settlementContract.address);

            expect(await vault.srtLocked(addr1.address)).to.equal(ethers.parseEther("150"));
            expect(await vault.srtStake(addr1.address)).to.equal(ethers.parseEther("150"));

            const settlementBalanceAfter = await suretyToken.balanceOf(settlementContract.address);
            expect(settlementBalanceAfter).to.equal(settlementBalanceBefore + slashAmount);
        });
    });
});
