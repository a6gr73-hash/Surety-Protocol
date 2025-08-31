// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/MerklePatriciaTrie.sol";

interface ICollateralVault {
    function reimburseAndStakeSRT(address user, uint256 amount) external;
    function reimburseAndStakeUSDC(address user, uint256 amount) external;
}

contract PoIClaimProcessor is Ownable {
    // --- State Variables ---
    ICollateralVault public immutable vault;
    address public immutable SRT;
    address public immutable USDC;

    // --- Structs ---
    struct PoIClaim {
        address payer;
        address merchant;
        address collateralToken;
        uint256 slashedAmount;
        uint256 timestamp;
        uint256 nonce;
        bytes[] slashedProof;
        bytes[] nonArrivalProof;
        bytes32 sourceShardRoot;
        bytes32 targetShardRoot;
        bool isVerified;
        bool isReimbursed;
        address relayer;
    }

    // --- Mappings and Events ---
    mapping(address => uint256) public nextNonce;
    mapping(bytes32 => PoIClaim) public claims;
    mapping(bytes32 => bool) public isShardRootPublished;

    event PoIClaimSubmitted(address indexed user, bytes32 claimId);
    event PoIClaimVerified(bytes32 claimId, uint256 reimbursedAmount);
    event PoIClaimRejected(bytes32 claimId);
    event PoIClaimReimbursed(bytes32 claimId, uint256 reimbursedAmount);

    // --- Constructor ---
    constructor(address _vault, address _srt, address _usdc) {
        require(_vault != address(0), "vault=0");
        require(_srt != address(0), "srt=0");
        require(_usdc != address(0), "usdc=0");
        vault = ICollateralVault(_vault);
        SRT = _srt;
        USDC = _usdc;
    }

    // --- Core Functions ---

    /**
     * @notice Submits a Proof of Innocence claim for a failed transaction.
     * @param claim The PoIClaim struct containing all claim data.
     * @param signature The user's signature over the hash of the encoded claim data.
     */
    function submitPoIClaim(PoIClaim calldata claim, bytes memory signature) external {
        require(claim.nonce == nextNonce[claim.payer], "Invalid nonce");

        // Re-encode the received struct to verify the hash that the user signed.
        bytes memory claimData = abi.encode(
            claim.payer, claim.merchant, claim.collateralToken, claim.slashedAmount,
            claim.timestamp, claim.nonce, claim.slashedProof, claim.nonArrivalProof,
            claim.sourceShardRoot, claim.targetShardRoot, claim.isVerified,
            claim.isReimbursed, claim.relayer
        );
        bytes32 claimHash = keccak256(claimData);
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", claimHash));
        
        address signer = recoverSigner(messageHash, signature);
        require(signer == claim.payer && signer != address(0), "Invalid signature");
        require(claims[claimHash].payer == address(0), "Claim already submitted");
        
        claims[claimHash] = claim;
        // The relayer is the actual transaction sender.
        claims[claimHash].relayer = msg.sender;

        nextNonce[claim.payer]++;
        emit PoIClaimSubmitted(claim.payer, claimHash);
    }

    /**
     * @notice Verifies the Merkle proofs for a submitted claim. Can only be called by the owner.
     * @param claimId The unique hash of the claim to verify.
     */
    function verifyPoIClaim(bytes32 claimId) external onlyOwner {
        PoIClaim storage claim = claims[claimId];
        require(claim.payer != address(0), "Claim does not exist");
        require(!claim.isVerified, "Claim already verified");
        require(isShardRootPublished[claim.sourceShardRoot], "Source root not published");
        require(isShardRootPublished[claim.targetShardRoot], "Target root not published");
        require(claim.slashedProof.length > 0, "Slashed proof missing");

        bytes memory txData = claim.slashedProof[0];
        bytes32 txHash = keccak256(txData);

        bool isProofOfDepartureValid = MerklePatriciaTrie.verifyInclusion(
            claim.slashedProof,
            claim.sourceShardRoot,
            abi.encodePacked(txHash),
            txData
        );
        
        bytes memory nonArrivalValue = MerklePatriciaTrie.get(
            claim.nonArrivalProof,
            claim.targetShardRoot,
            abi.encodePacked(txHash)
        );
        bool isProofOfNonArrivalValid = nonArrivalValue.length == 0;

        if (isProofOfDepartureValid && isProofOfNonArrivalValid) {
            claim.isVerified = true;
            emit PoIClaimVerified(claimId, claim.slashedAmount);
        } else {
            emit PoIClaimRejected(claimId);
        }
    }

    /**
     * @notice Publishes a shard's state root to this contract. Can only be called by the owner.
     * @param root The state root to publish.
     */
    function publishShardRoot(bytes32 root) external onlyOwner {
        isShardRootPublished[root] = true;
    }

    /**
     * @notice Reimburses a user for a verified claim. Can only be called by the owner.
     * @param claimId The unique hash of the claim to reimburse.
     */
    function reimburseSlashedFunds(bytes32 claimId) external onlyOwner {
        PoIClaim storage claim = claims[claimId];
        require(claim.isVerified, "Claim not verified");
        require(!claim.isReimbursed, "Claim already reimbursed");

        claim.isReimbursed = true;
        
        if (claim.collateralToken == SRT) {
            vault.reimburseAndStakeSRT(claim.payer, claim.slashedAmount);
        } else if (claim.collateralToken == USDC) {
            vault.reimburseAndStakeUSDC(claim.payer, claim.slashedAmount);
        } else {
            revert("Unsupported collateral token");
        }
        
        emit PoIClaimReimbursed(claimId, claim.slashedAmount);
    }
    
    /**
     * @dev Recovers the signer's address from a message hash and signature.
     */
    function recoverSigner(bytes32 _messageHash, bytes memory _signature) internal pure returns (address) {
        require(_signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }
        if (v < 27) v += 27;
        return ecrecover(_messageHash, v, r, s);
    }
}