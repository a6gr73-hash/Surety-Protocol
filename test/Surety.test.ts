import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { Surety, MockOracle } from "../typechain-types";

describe("Surety Token", function () {
    let suretyToken: Surety;
    let mockOracle: MockOracle;
    let owner: SignerWithAddress;

    // The oracle price of 1 SRT in USD, with 8 decimals
    const initialSrtPrice = ethers.parseUnits("1", 8); // $1.00

    beforeEach(async function () {
        [owner] = await ethers.getSigners();
        
        // Deploy the MockOracle first
        const MockOracleFactory = await ethers.getContractFactory("MockOracle");
        mockOracle = await MockOracleFactory.deploy(initialSrtPrice);
        await mockOracle.waitForDeployment();
        
        // Deploy the Surety contract with the MockOracle's address
        const SuretyFactory = await ethers.getContractFactory("Surety");
        suretyToken = await SuretyFactory.deploy(mockOracle.target);
        await suretyToken.waitForDeployment();
    });

    it("Should mint the total supply to the deployer's address", async function () {
        const totalSupply = await suretyToken.totalSupply();
        const expectedSupply = ethers.parseEther("1000000000");

        expect(totalSupply).to.equal(expectedSupply);
    });

    it("Should have the correct name and symbol", async function () {
        expect(await suretyToken.name()).to.equal("Surety");
        expect(await suretyToken.symbol()).to.equal("SRT");
    });
});