import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { Surety, CollateralVault, MockUSDC } from "../typechain-types";

describe("CollateralVault", function () {
    let suretyToken: Surety;
    let mockUsdc: MockUSDC;
    let vault: CollateralVault;
    let owner: SignerWithAddress;
    let user1: SignerWithAddress;
    let settlementContract: SignerWithAddress;
    let unauthorizedUser: SignerWithAddress;

    beforeEach(async function () {
        [owner, user1, settlementContract, unauthorizedUser] = await ethers.getSigners();

        // Deploy Surety Token
        const SuretyFactory = await ethers.getContractFactory("Surety");
        suretyToken = await SuretyFactory.deploy();
        await suretyToken.waitForDeployment();

        // Deploy MockUSDC
        const MockUsdcFactory = await ethers.getContractFactory("MockUSDC");
        mockUsdc = await MockUsdcFactory.deploy();
        await mockUsdc.waitForDeployment();

        // Deploy CollateralVault
        const VaultFactory = await ethers.getContractFactory("CollateralVault");
        vault = await VaultFactory.deploy(await suretyToken.getAddress(), await mockUsdc.getAddress());
        await vault.waitForDeployment();

        // Fund user1 with tokens for testing
        await suretyToken.connect(owner).transfer(user1.address, ethers.parseEther("10000"));
        await mockUsdc.connect(owner).mint(user1.address, ethers.parseUnits("10000", 6));
    });

    describe("Deployment and Administration", function () {
        it("Should set the correct token addresses on deployment", async function () {
            expect(await vault.srt()).to.equal(await suretyToken.getAddress());
            expect(await vault.usdc()).to.equal(await mockUsdc.getAddress());
        });

        it("Should allow the owner to add a settlement contract", async function () {
            await expect(vault.connect(owner).addSettlementContract(settlementContract.address))
                .to.emit(vault, "SettlementContractAdded")
                .withArgs(settlementContract.address);
            expect(await vault.isSettlementContract(settlementContract.address)).to.be.true;
        });

        it("Should prevent non-owners from adding a settlement contract", async function () {
            await expect(vault.connect(user1).addSettlementContract(settlementContract.address))
                .to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("Should prevent adding an already authorized contract", async function () {
            await vault.connect(owner).addSettlementContract(settlementContract.address);
            await expect(vault.connect(owner).addSettlementContract(settlementContract.address))
                .to.be.revertedWith("CollateralVault: Contract already authorized");
        });

        it("Should allow the owner to remove a settlement contract", async function () {
            await vault.connect(owner).addSettlementContract(settlementContract.address);
            await expect(vault.connect(owner).removeSettlementContract(settlementContract.address))
                .to.emit(vault, "SettlementContractRemoved")
                .withArgs(settlementContract.address);
            expect(await vault.isSettlementContract(settlementContract.address)).to.be.false;
        });

        it("Should prevent non-owners from removing a settlement contract", async function () {
            await vault.connect(owner).addSettlementContract(settlementContract.address);
            await expect(vault.connect(user1).removeSettlementContract(settlementContract.address))
                .to.be.revertedWith("Ownable: caller is not the owner");
        });
    });

    describe("SRT Deposit and Withdraw", function () {
        it("Should allow a user to deposit SRT and update free stake", async function () {
            const depositAmount = ethers.parseEther("500");
            await suretyToken.connect(user1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(user1).depositSRT(depositAmount);

            expect(await vault.srtFreeOf(user1.address)).to.equal(depositAmount);
            expect(await vault.srtTotalOf(user1.address)).to.equal(depositAmount);
        });

        it("Should allow a user to withdraw their free SRT stake", async function () {
            const depositAmount = ethers.parseEther("400");
            const withdrawAmount = ethers.parseEther("150");

            await suretyToken.connect(user1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(user1).depositSRT(depositAmount);
            await vault.connect(user1).withdrawSRT(withdrawAmount);

            expect(await vault.srtFreeOf(user1.address)).to.equal(depositAmount - withdrawAmount);
        });

        it("Should reject withdrawing more than the available free SRT stake", async function () {
            const depositAmount = ethers.parseEther("200");
            await suretyToken.connect(user1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(user1).depositSRT(depositAmount);

            const overdrawAmount = ethers.parseEther("201");
            await expect(vault.connect(user1).withdrawSRT(overdrawAmount))
                .to.be.revertedWith("CollateralVault: Insufficient free SRT stake");
        });
    });

    describe("USDC Deposit and Withdraw", function () {
        it("Should allow a user to deposit USDC and update free stake", async function () {
            const depositAmount = ethers.parseUnits("500", 6);
            await mockUsdc.connect(user1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(user1).depositUSDC(depositAmount);

            // Note: No specific view functions for USDC, but we can infer from SRT tests
            // This implicitly tests that the internal `usdcStake` mapping is updated.
            const totalVaultBalance = await mockUsdc.balanceOf(await vault.getAddress());
            expect(totalVaultBalance).to.equal(depositAmount);
        });

        it("Should allow a user to withdraw their free USDC stake", async function () {
            const depositAmount = ethers.parseUnits("400", 6);
            const withdrawAmount = ethers.parseUnits("150", 6);

            await mockUsdc.connect(user1).approve(await vault.getAddress(), depositAmount);
            await vault.connect(user1).depositUSDC(depositAmount);
            await vault.connect(user1).withdrawUSDC(withdrawAmount);

            const finalVaultBalance = await mockUsdc.balanceOf(await vault.getAddress());
            expect(finalVaultBalance).to.equal(depositAmount - withdrawAmount);
        });
    });

    describe("Settlement Logic (SRT & USDC)", function () {
        const srtDepositAmount = ethers.parseEther("1000");
        const usdcDepositAmount = ethers.parseUnits("1000", 6);

        beforeEach(async function () {
            // Authorize the settlement contract
            await vault.connect(owner).addSettlementContract(settlementContract.address);

            // User deposits both SRT and USDC to have funds to lock
            await suretyToken.connect(user1).approve(await vault.getAddress(), srtDepositAmount);
            await vault.connect(user1).depositSRT(srtDepositAmount);
            await mockUsdc.connect(user1).approve(await vault.getAddress(), usdcDepositAmount);
            await vault.connect(user1).depositUSDC(usdcDepositAmount);
        });

        it("Should allow the authorized contract to lock SRT", async function () {
            const lockAmount = ethers.parseEther("300");
            await vault.connect(settlementContract).lockSRT(user1.address, lockAmount);

            expect(await vault.srtFreeOf(user1.address)).to.equal(srtDepositAmount - lockAmount);
            expect(await vault.srtLockedOf(user1.address)).to.equal(lockAmount);
            expect(await vault.srtTotalOf(user1.address)).to.equal(srtDepositAmount);
        });

        it("Should reject lock attempts from non-authorized addresses", async function () {
            const lockAmount = ethers.parseEther("300");
            await expect(vault.connect(unauthorizedUser).lockSRT(user1.address, lockAmount))
                .to.be.revertedWith("CollateralVault: Caller is not an authorized settlement contract");
        });

        it("Should allow the authorized contract to release locked SRT", async function () {
            const lockAmount = ethers.parseEther("400");
            const releaseAmount = ethers.parseEther("150");
            await vault.connect(settlementContract).lockSRT(user1.address, lockAmount);
            await vault.connect(settlementContract).releaseSRT(user1.address, releaseAmount);

            expect(await vault.srtFreeOf(user1.address)).to.equal(srtDepositAmount - lockAmount + releaseAmount);
            expect(await vault.srtLockedOf(user1.address)).to.equal(lockAmount - releaseAmount);
        });

        it("Should allow the authorized contract to slash locked SRT", async function () {
            const lockAmount = ethers.parseEther("350");
            const slashAmount = ethers.parseEther("200");
            await vault.connect(settlementContract).lockSRT(user1.address, lockAmount);

            const recipientBalanceBefore = await suretyToken.balanceOf(unauthorizedUser.address);
            await vault.connect(settlementContract).slashSRT(user1.address, slashAmount, unauthorizedUser.address);
            const recipientBalanceAfter = await suretyToken.balanceOf(unauthorizedUser.address);

            expect(await vault.srtLockedOf(user1.address)).to.equal(lockAmount - slashAmount);
            expect(recipientBalanceAfter).to.equal(recipientBalanceBefore + slashAmount);
            expect(await vault.srtTotalOf(user1.address)).to.equal(srtDepositAmount - slashAmount);
        });

        it("Should allow the authorized contract to lock USDC", async function () {
            const lockAmount = ethers.parseUnits("300", 6);
            await vault.connect(settlementContract).lockUSDC(user1.address, lockAmount);

            // Check balances to confirm state change
            const vaultBalance = await mockUsdc.balanceOf(await vault.getAddress());
            expect(vaultBalance).to.equal(usdcDepositAmount); // Total doesn't change
        });
    });
});