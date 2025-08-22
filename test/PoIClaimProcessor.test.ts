import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { PoIClaimProcessor, CollateralVault, Surety, MockERC20 } from "../typechain-types";
import { Trie } from "@ethereumjs/trie";
import { Buffer } from "buffer";
import { TypedDataEncoder } from "ethers";

describe("PoIClaimProcessor EIP-712", function () {
  let poiProcessor: PoIClaimProcessor;
  let vault: CollateralVault;
  let srtToken: Surety;
  let usdcToken: MockERC20;
  let owner: SignerWithAddress;
  let payer: SignerWithAddress;
  let merchant: SignerWithAddress;
  let relayer: SignerWithAddress;
  let claimId: string;
  let valueForSigning: any;
  let domain: any;
  let types: any;

  beforeEach(async function () {
    [owner, payer, merchant, relayer] = await ethers.getSigners();

    const SuretyFactory = await ethers.getContractFactory("Surety");
    srtToken = await SuretyFactory.deploy(ethers.parseEther("1000000"));
    await srtToken.waitForDeployment();

    const MockUsdcFactory = await ethers.getContractFactory("MockERC20");
    usdcToken = await MockUsdcFactory.deploy("Mock USDC", "mUSDC");
    await usdcToken.waitForDeployment();

    const VaultFactory = await ethers.getContractFactory("CollateralVault");
    vault = await VaultFactory.deploy(await srtToken.getAddress(), await usdcToken.getAddress());
    await vault.waitForDeployment();

    const PoIProcessorFactory = await ethers.getContractFactory("PoIClaimProcessor");
    poiProcessor = await PoIProcessorFactory.deploy();
    await poiProcessor.waitForDeployment();

    // --- Test Setup ---
    const sourceTrie = new Trie();
    const targetTrie = new Trie();
    const slashedTxData = '0x' + Buffer.from("example-slashed-transaction").toString('hex');
    const slashedTxHashHex = ethers.keccak256(slashedTxData);
    const keyBuf = Buffer.from(slashedTxHashHex.slice(2), 'hex');
    await sourceTrie.put(keyBuf, Buffer.from(slashedTxData.slice(2), 'hex'));
    const rawSlashedProof = await sourceTrie.createProof(keyBuf);
    const rawNonArrivalProof = await targetTrie.createProof(keyBuf);
    const slashedProof = rawSlashedProof.map(n => '0x' + Buffer.from(n).toString('hex'));
    const nonArrivalProof = rawNonArrivalProof.map(n => '0x' + Buffer.from(n).toString('hex'));

    // --- EIP-712 Setup ---
    const chainId = (await ethers.provider.getNetwork()).chainId;
    domain = {
      name: "SPP-PoIClaim",
      version: "1",
      chainId: chainId,
      verifyingContract: await poiProcessor.getAddress()
    };

    types = {
      Claim: [
        { name: "payer", type: "address" },
        { name: "merchant", type: "address" },
        { name: "collateralToken", type: "address" },
        { name: "slashedAmount", type: "uint256" },
        { name: "timestamp", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "slashedTxDataHash", type: "bytes32" },
        { name: "slashedProofHash", type: "bytes32" },
        { name: "nonArrivalProofHash", type: "bytes32" },
        { name: "sourceShardRoot", type: "bytes32" },
        { name: "targetShardRoot", type: "bytes32" }
      ]
    };

    const slashedProofHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['bytes[]'], [slashedProof]));
    const nonArrivalProofHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(['bytes[]'], [nonArrivalProof]));

    const nonce = await poiProcessor.nextNonce(payer.address);

    // ⭐ FIX: Convert Uint8Array from trie.root() to a Buffer before creating the hex string.
    const sourceShardRootHex = '0x' + Buffer.from(sourceTrie.root()).toString('hex');
    const targetShardRootHex = '0x' + Buffer.from(targetTrie.root()).toString('hex');

    valueForSigning = {
      payer: payer.address,
      merchant: merchant.address,
      collateralToken: await usdcToken.getAddress(),
      slashedAmount: ethers.parseUnits("100", 6),
      timestamp: Math.floor(Date.now() / 1000),
      nonce,
      slashedTxDataHash: slashedTxHashHex,
      slashedProofHash,
      nonArrivalProofHash,
      sourceShardRoot: sourceShardRootHex,
      targetShardRoot: targetShardRootHex
    };

    claimId = TypedDataEncoder.hash(domain, types, valueForSigning);
  });

  describe("Claim Submission", function () {
    it("Allows a relayer to submit a valid claim", async function () {
      const signature = await payer.signTypedData(domain, types, valueForSigning);
      await expect(
        poiProcessor.connect(relayer).submitPoIClaim(
          valueForSigning.payer,
          valueForSigning.merchant,
          valueForSigning.collateralToken,
          valueForSigning.slashedAmount,
          valueForSigning.timestamp,
          valueForSigning.nonce,
          valueForSigning.slashedTxDataHash,
          valueForSigning.slashedProofHash,
          valueForSigning.nonArrivalProofHash,
          valueForSigning.sourceShardRoot,
          valueForSigning.targetShardRoot,
          signature
        )
      ).to.emit(poiProcessor, "PoIClaimSubmitted").withArgs(payer.address, claimId);
    });

    it("Rejects invalid signatures", async function () {
      const badValue = {
        payer: valueForSigning.payer,
        merchant: valueForSigning.merchant,
        collateralToken: valueForSigning.collateralToken,
        slashedAmount: valueForSigning.slashedAmount,
        timestamp: valueForSigning.timestamp,
        nonce: 999, // The only change is the nonce
        slashedTxDataHash: valueForSigning.slashedTxDataHash,
        slashedProofHash: valueForSigning.slashedProofHash,
        nonArrivalProofHash: valueForSigning.nonArrivalProofHash,
        sourceShardRoot: valueForSigning.sourceShardRoot,
        targetShardRoot: valueForSigning.targetShardRoot,
      };

      // Sign the incorrect value to create a signature that will not match the on-chain hash
      const invalidSignature = await payer.signTypedData(domain, types, badValue);

      // Use the original, correct values to test the rejection
      await expect(
        poiProcessor.connect(relayer).submitPoIClaim(
          valueForSigning.payer,
          valueForSigning.merchant,
          valueForSigning.collateralToken,
          valueForSigning.slashedAmount,
          valueForSigning.timestamp,
          valueForSigning.nonce,
          valueForSigning.slashedTxDataHash,
          valueForSigning.slashedProofHash,
          valueForSigning.nonArrivalProofHash,
          valueForSigning.sourceShardRoot,
          valueForSigning.targetShardRoot,
          invalidSignature // This is the bad signature
        )
      ).to.be.revertedWith("PoI: invalid signature");
    });
  });

  describe("Claim Verification", function () {
    beforeEach(async function () {
      const signature = await payer.signTypedData(domain, types, valueForSigning);
      await poiProcessor.connect(relayer).submitPoIClaim(
        valueForSigning.payer, valueForSigning.merchant, valueForSigning.collateralToken,
        valueForSigning.slashedAmount, valueForSigning.timestamp, valueForSigning.nonce,
        valueForSigning.slashedTxDataHash, valueForSigning.slashedProofHash, valueForSigning.nonArrivalProofHash,
        valueForSigning.sourceShardRoot, valueForSigning.targetShardRoot, signature
      );
    });

    it("Owner can verify a valid claim", async function () {
      const ownerConnectedProcessor = poiProcessor.connect(owner);
      await ownerConnectedProcessor.publishShardRoot(valueForSigning.sourceShardRoot);
      await ownerConnectedProcessor.publishShardRoot(valueForSigning.targetShardRoot);

      await expect(ownerConnectedProcessor.verifyPoIClaim(claimId))
        .to.emit(poiProcessor, "PoIClaimVerified")
        .withArgs(claimId, valueForSigning.slashedAmount);
    });
  });

  describe("Reimbursement", function () {
    beforeEach(async function () {
      const signature = await payer.signTypedData(domain, types, valueForSigning);
      await poiProcessor.connect(relayer).submitPoIClaim(
        valueForSigning.payer, valueForSigning.merchant, valueForSigning.collateralToken,
        valueForSigning.slashedAmount, valueForSigning.timestamp, valueForSigning.nonce,
        valueForSigning.slashedTxDataHash, valueForSigning.slashedProofHash, valueForSigning.nonArrivalProofHash,
        valueForSigning.sourceShardRoot, valueForSigning.targetShardRoot, signature
      );

      const ownerConnectedProcessor = poiProcessor.connect(owner);
      await ownerConnectedProcessor.publishShardRoot(valueForSigning.sourceShardRoot);
      await ownerConnectedProcessor.publishShardRoot(valueForSigning.targetShardRoot);
      await ownerConnectedProcessor.verifyPoIClaim(claimId);
    });

    it("Owner can mark a verified claim as reimbursed and check the state", async function () {
      await expect(poiProcessor.connect(owner).reimburseSlashedFunds(claimId))
        .to.emit(poiProcessor, "PoIClaimReimbursed")
        .withArgs(claimId, valueForSigning.slashedAmount);

      const claim = await poiProcessor.claims(claimId);
      expect(claim.isReimbursed).to.be.true;
    });

    it("Rejects reimbursement if already processed", async function () {
      await poiProcessor.connect(owner).reimburseSlashedFunds(claimId);

      await expect(
        poiProcessor.connect(owner).reimburseSlashedFunds(claimId)
      ).to.be.revertedWith("PoI: already reimbursed");
    });
  });
});