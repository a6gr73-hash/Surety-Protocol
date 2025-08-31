import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { Surety } from "../typechain-types";

describe("Surety Token", function () {
    let suretyToken: Surety;
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;
    let initialSupply: bigint;

    beforeEach(async function () {
        [owner, addr1] = await ethers.getSigners();

        // This value is still needed for the tests, it just isn't passed to the constructor.
        initialSupply = ethers.parseEther("1000000000"); // 1 Billion SRT

        const SuretyFactory = await ethers.getContractFactory("Surety");
        
        // CORRECTED: The deploy function is called with no arguments.
        suretyToken = (await SuretyFactory.deploy()) as unknown as Surety;
        await suretyToken.waitForDeployment();
    });

    it("Should have the correct name and symbol", async function () {
        expect(await suretyToken.name()).to.equal("Surety");
        expect(await suretyToken.symbol()).to.equal("SRT");
    });

    it("Should mint the total supply to the deployer's address", async function () {
        const totalSupply = await suretyToken.totalSupply();
        const ownerBalance = await suretyToken.balanceOf(owner.address);

        expect(totalSupply).to.equal(initialSupply);
        expect(ownerBalance).to.equal(initialSupply);
    });

    it("Should not have a mint function for non-owners", async function () {
        // This test confirms that the public mint function was removed as per the final contract.
        // The 'any' type is used to check for the absence of the function at runtime.
        expect((suretyToken.connect(addr1) as any).mint).to.be.undefined;
    });

    it("Should allow the owner to burn tokens from any address", async function () {
        const burnAmount = ethers.parseEther("100");
        const initialOwnerBalance = await suretyToken.balanceOf(owner.address);

        await suretyToken.connect(owner).burn(owner.address, burnAmount);

        const expectedBalance = initialOwnerBalance - burnAmount;
        expect(await suretyToken.balanceOf(owner.address)).to.equal(expectedBalance);
        expect(await suretyToken.totalSupply()).to.equal(initialSupply - burnAmount);
    });

    it("Should not allow non-owners to burn tokens", async function () {
        const amount = ethers.parseEther("100");

        await expect(suretyToken.connect(addr1).burn(owner.address, amount))
            .to.be.revertedWith("Ownable: caller is not the owner");
    });
});