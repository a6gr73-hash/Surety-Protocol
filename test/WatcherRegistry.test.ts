import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { WatcherRegistry, CollateralVault, Surety, MockUSDC } from "../typechain-types";

describe("WatcherRegistry (Production)", function () {
    let watcherRegistry: WatcherRegistry;
    let collateralVault: CollateralVault;
    let suretyToken: Surety;
    let mockUsdc: MockUSDC;
    let owner: SignerWithAddress;
    let watcher: SignerWithAddress;
    let nonWatcher: SignerWithAddress;
    
    const MIN_STAKE = ethers.parseEther("5000");
    const UNSTAKE_BLOCKS = 216000;

    beforeEach(async function () {
        [owner, watcher, nonWatcher] = await ethers.getSigners();
        
        // Deploy dependencies
        suretyToken = await ethers.deployContract("Surety");
        mockUsdc = await ethers.deployContract("MockUSDC");
        collateralVault = await ethers.deployContract("CollateralVault", [
            await suretyToken.getAddress(),
            await mockUsdc.getAddress()
        ]);
        
        // Deploy WatcherRegistry with all required constructor arguments
        watcherRegistry = await ethers.deployContract("WatcherRegistry", [
            await collateralVault.getAddress(),
            await mockUsdc.getAddress(), // New argument
            MIN_STAKE
        ]);

        // Authorize the registry in the vault
        await collateralVault.addSettlementContract(await watcherRegistry.getAddress());

        // Setup: Fund the watcher with SRT and have them deposit it into the vault
        await suretyToken.transfer(watcher.address, ethers.parseEther("10000"));
        await suretyToken.connect(watcher).approve(await collateralVault.getAddress(), ethers.parseEther("10000"));
        await collateralVault.connect(watcher).depositSRT(ethers.parseEther("10000"));
    });

    describe("Watcher Registration", function () {
        it("Should allow a user with enough free stake to register", async function () {
            await expect(watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE))
                .to.emit(watcherRegistry, "WatcherRegistered")
                .withArgs(watcher.address, MIN_STAKE);
            
            expect(await watcherRegistry.isWatcher(watcher.address)).to.be.true;
            expect(await collateralVault.srtLockedOf(watcher.address)).to.equal(MIN_STAKE);
        });

        it("Should fail registration if minimum stake is not met", async function () {
            const insufficientStake = MIN_STAKE - 1n;
            await expect(watcherRegistry.connect(watcher).registerWatcher(insufficientStake))
                .to.be.revertedWith("WatcherRegistry: Insufficient stake amount");
        });

        it("Should fail if the user is already a watcher", async function () {
            await watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE);
            await expect(watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE))
                .to.be.revertedWith("WatcherRegistry: Already registered");
        });
    });

    describe("Deregistration and Claiming", function () {
        beforeEach(async function () {
            await watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE);
        });

        it("Should allow a watcher to deregister and start the unstake period", async function () {
            await watcherRegistry.connect(watcher).deregisterWatcher();
            const requestBlock = await watcherRegistry.unstakeRequestBlock(watcher.address);
            expect(requestBlock).to.be.above(0);
        });

        it("Should allow a watcher to claim funds after the unstake period", async function () {
            await watcherRegistry.connect(watcher).deregisterWatcher();
            
            // Mine blocks to simulate the unstake period passing
            await ethers.provider.send('hardhat_mine', [ethers.toQuantity(UNSTAKE_BLOCKS + 1)]);

            await expect(watcherRegistry.connect(watcher).claimUnstakedFunds())
                .to.emit(watcherRegistry, "WatcherFundsClaimed");
            
            expect(await collateralVault.srtLockedOf(watcher.address)).to.equal(0);
            expect(await collateralVault.srtFreeOf(watcher.address)).to.equal(ethers.parseEther("10000"));
            expect(await watcherRegistry.isWatcher(watcher.address)).to.be.false;
        });
    });

    describe("Stipend Distribution", function () {
        const stipendAmount = ethers.parseUnits("100", 6);

        beforeEach(async function () {
            // Register the watcher
            await watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE);
            
            // Fund the WatcherRegistry contract from the treasury (owner)
            const totalDistribution = stipendAmount * 1n;
            await mockUsdc.mint(owner.address, totalDistribution);
            await mockUsdc.connect(owner).transfer(await watcherRegistry.getAddress(), totalDistribution);
        });

        it("Should allow the owner to distribute stipends to active watchers", async function () {
            const watcherBalanceBefore = await mockUsdc.balanceOf(watcher.address);

            await expect(watcherRegistry.connect(owner).distributeStipends([watcher.address], stipendAmount))
                .to.emit(watcherRegistry, "StipendsDistributed");

            const watcherBalanceAfter = await mockUsdc.balanceOf(watcher.address);
            expect(watcherBalanceAfter).to.equal(watcherBalanceBefore + stipendAmount);
        });

        it("Should prevent non-owners from distributing stipends", async function () {
            await expect(watcherRegistry.connect(nonWatcher).distributeStipends([watcher.address], stipendAmount))
                .to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("Should revert if the contract has an insufficient USDC balance", async function () {
            // Try to distribute more than the contract holds
            const excessiveAmount = stipendAmount + 1n;
            await expect(watcherRegistry.connect(owner).distributeStipends([watcher.address], excessiveAmount))
                .to.be.revertedWith("WatcherRegistry: Insufficient USDC balance for distribution");
        });

        it("Should revert if trying to pay a stipend to a non-watcher", async function () {
            await expect(watcherRegistry.connect(owner).distributeStipends([nonWatcher.address], stipendAmount))
                .to.be.revertedWith("WatcherRegistry: Cannot pay stipend to a non-watcher");
        });
    });
});