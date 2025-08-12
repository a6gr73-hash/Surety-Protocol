import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";

// We define a "fixture" -- a setup function that can be reused for every test.
async function deploySuretyFixture() {
  // Get the signers (accounts)
  const [owner, otherAccount] = await ethers.getSigners();

  // Get the contract factory for our "Surety" contract
  const Surety = await ethers.getContractFactory("Surety");

  // Deploy the contract
  const suretyToken = await Surety.deploy();

  // Return all the values we'll need for our tests
  return { suretyToken, owner, otherAccount };
}

describe("Surety Token", function () {
  describe("Deployment", function () {
    it("Should mint the total supply to the deployer's address", async function () {
      // Run our fixture to get a clean state for this test
      const { suretyToken, owner } = await loadFixture(deploySuretyFixture);

      const ownerBalance = await suretyToken.balanceOf(owner.address);
      const totalSupply = await suretyToken.totalSupply();

      // Check that the owner's balance equals the total supply
      expect(ownerBalance).to.equal(totalSupply);
    });

    it("Should have the correct name and symbol", async function () {
      // Run the fixture again
      const { suretyToken } = await loadFixture(deploySuretyFixture);

      // Check the token's name and symbol
      expect(await suretyToken.name()).to.equal("Surety");
      expect(await suretyToken.symbol()).to.equal("SRT");
    });
  });
});