import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { WatcherRegistry, CollateralVault, Surety } from "../typechain-types";

describe("WatcherRegistry", function () {
    let watcherRegistry: WatcherRegistry;
    let collateralVault: CollateralVault;
    let suretyToken: Surety;
    let owner: SignerWithAddress;
    let watcher: SignerWithAddress;
    let nonWatcher: SignerWithAddress;
    
    const MIN_STAKE = ethers.parseEther("1000");
    const UNSTAKE_BLOCKS = 216000;

    beforeEach(async function () {
        [owner, watcher, nonWatcher] = await ethers.getSigners();
        
        const SuretyFactory = await ethers.getContractFactory("Surety");
        suretyToken = await SuretyFactory.deploy(ethers.parseEther("10000000"));
        await suretyToken.waitForDeployment();
        
        const CollateralVaultFactory = await ethers.getContractFactory("CollateralVault");
        const usdcAddress = await suretyToken.getAddress();
        collateralVault = await CollateralVaultFactory.deploy(await suretyToken.getAddress(), usdcAddress);
        await collateralVault.waitForDeployment();
        
        const WatcherRegistryFactory = await ethers.getContractFactory("WatcherRegistry");
        watcherRegistry = await WatcherRegistryFactory.deploy(await collateralVault.getAddress(), MIN_STAKE);
        await watcherRegistry.waitForDeployment();

        await collateralVault.connect(owner).setSettlementContract(await watcherRegistry.getAddress());

        await suretyToken.transfer(watcher.address, ethers.parseEther("2000"));
        await suretyToken.connect(watcher).approve(await collateralVault.getAddress(), ethers.parseEther("2000"));
        await collateralVault.connect(watcher).depositSRT(ethers.parseEther("2000"));
    });

    describe("Deployment", function () {
        it("Should set the correct vault address and minimum stake", async function () {
            expect(await watcherRegistry.collateralVault()).to.equal(await collateralVault.getAddress());
            expect(await watcherRegistry.minWatcherStake()).to.equal(MIN_STAKE);
        });
    });

    describe("Watcher Registration", function () {
        it("Should allow a user with enough free stake to register", async function () {
            await expect(watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE))
                .to.emit(watcherRegistry, "WatcherRegistered")
                .withArgs(watcher.address, MIN_STAKE);
            
            expect(await watcherRegistry.isWatcher(watcher.address)).to.be.true;
            expect(await collateralVault.srtLocked(watcher.address)).to.equal(MIN_STAKE);
            expect(await collateralVault.srtStake(watcher.address)).to.equal(MIN_STAKE);
        });

        it("Should fail registration if minimum stake is not met", async function () {
            const insufficientStake = MIN_STAKE - ethers.parseEther("1");
            // ⭐ FIX: Updated revert reason string
            await expect(watcherRegistry.connect(watcher).registerWatcher(insufficientStake))
                .to.be.revertedWith("WatcherRegistry: Insufficient stake amount");
        });

        it("Should fail if the user is already a watcher", async function () {
            await watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE);
            // ⭐ FIX: Updated revert reason string
            await expect(watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE))
                .to.be.revertedWith("WatcherRegistry: Already registered");
        });
    });

    describe("Watcher Deregistration", function () {
        beforeEach(async function () {
            await watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE);
        });

        it("Should allow a watcher to deregister and start the unstake period", async function () {
            await watcherRegistry.connect(watcher).deregisterWatcher();
            const requestBlock = await watcherRegistry.unstakeRequestBlock(watcher.address);
            expect(requestBlock).to.be.above(0);
        });

        it("Should fail if a non-watcher tries to deregister", async function () {
            // ⭐ FIX: Updated revert reason string
            await expect(watcherRegistry.connect(nonWatcher).deregisterWatcher())
                .to.be.revertedWith("WatcherRegistry: Not a registered watcher");
        });

        it("Should fail to claim funds before the unstake period is over", async function () {
            await watcherRegistry.connect(watcher).deregisterWatcher();
            // ⭐ FIX: Updated revert reason string
            await expect(watcherRegistry.connect(watcher).claimUnstakedFunds())
                .to.be.revertedWith("WatcherRegistry: Unstake period not over");
        });

        it("Should allow a watcher to claim funds after the unstake period", async function () {
            await watcherRegistry.connect(watcher).deregisterWatcher();
            
            await ethers.provider.send('hardhat_mine', [ethers.toQuantity(UNSTAKE_BLOCKS + 1)]);

            await watcherRegistry.connect(watcher).claimUnstakedFunds();
            
            const lockedBalanceAfter = await collateralVault.srtLocked(watcher.address);
            const freeBalanceAfter = await collateralVault.srtStake(watcher.address);
            
            expect(lockedBalanceAfter).to.equal(0);
            expect(freeBalanceAfter).to.equal(ethers.parseEther("2000"));
        });
    });

    describe("Slashing and Admin", function () {
        beforeEach(async function () {
            await watcherRegistry.connect(watcher).registerWatcher(MIN_STAKE);
        });

        it("Should allow the owner to slash a watcher", async function () {
            const slashAmount = ethers.parseEther("500");
            const ownerBalanceBefore = await suretyToken.balanceOf(owner.address);
            const watcherLockedBefore = await collateralVault.srtLocked(watcher.address);
            
            await watcherRegistry.connect(owner).slashWatcher(watcher.address, slashAmount, owner.address);

            const ownerBalanceAfter = await suretyToken.balanceOf(owner.address);
            const watcherLockedAfter = await collateralVault.srtLocked(watcher.address);
            
            expect(watcherLockedAfter).to.equal(watcherLockedBefore - slashAmount);
            expect(ownerBalanceAfter).to.equal(ownerBalanceBefore + slashAmount);
        });

        it("Should prevent non-owners from slashing a watcher", async function () {
            const slashAmount = ethers.parseEther("500");
            await expect(watcherRegistry.connect(nonWatcher).slashWatcher(watcher.address, slashAmount, nonWatcher.address))
                .to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("Should allow the owner to set a new minimum stake", async function () {
            const newMinStake = ethers.parseEther("2000");
            await watcherRegistry.connect(owner).setMinWatcherStake(newMinStake);
            expect(await watcherRegistry.minWatcherStake()).to.equal(newMinStake);
        });
    });
});