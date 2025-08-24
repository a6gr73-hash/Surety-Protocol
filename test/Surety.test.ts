import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { Surety } from "../typechain-types";

describe("Surety Token", function () {
    let suretyToken: Surety;
    let owner: SignerWithAddress;
    let addr1: SignerWithAddress;
    let addr2: SignerWithAddress;

    beforeEach(async function () {
        [owner, addr1, addr2] = await ethers.getSigners();
        
        // Deploy the Surety contract with no constructor arguments
        const SuretyFactory = await ethers.getContractFactory("Surety");
        suretyToken = await SuretyFactory.deploy();
        await suretyToken.waitForDeployment();
    });

    it("Should have the correct name and symbol", async function () {
        expect(await suretyToken.name()).to.equal("Surety");
        expect(await suretyToken.symbol()).to.equal("SRT");
    });

    it("Should mint the total fixed supply to the deployer's address", async function () {
        const initialSupply = ethers.parseEther("1000000000");
        const totalSupply = await suretyToken.totalSupply();
        const ownerBalance = await suretyToken.balanceOf(owner.address);

        expect(totalSupply).to.equal(initialSupply);
        expect(ownerBalance).to.equal(initialSupply);
    });

    it("Should allow the owner to burn tokens from any address", async function () {
        const transferAmount = ethers.parseEther("500");
        const burnAmount = ethers.parseEther("100");

        // Transfer some tokens from the owner to addr1
        await suretyToken.connect(owner).transfer(addr1.address, transferAmount);

        const initialAddr1Balance = await suretyToken.balanceOf(addr1.address);
        const initialTotalSupply = await suretyToken.totalSupply();

        // Owner burns tokens from addr1's address
        await suretyToken.connect(owner).burn(addr1.address, burnAmount);
        
        const expectedAddr1Balance = initialAddr1Balance - burnAmount;
        const expectedTotalSupply = initialTotalSupply - burnAmount;

        expect(await suretyToken.balanceOf(addr1.address)).to.equal(expectedAddr1Balance);
        expect(await suretyToken.totalSupply()).to.equal(expectedTotalSupply);
    });

    it("Should not allow non-owners to burn tokens", async function () {
        const burnAmount = ethers.parseEther("100");
        
        await expect(suretyToken.connect(addr1).burn(owner.address, burnAmount))
            .to.be.revertedWith("Ownable: caller is not the owner");
    });
    
    it("Should not have a mint function", async function () {
        const hasMintFunction = typeof (suretyToken as any).mint === "function";
        expect(hasMintFunction).to.be.false;
    });
});