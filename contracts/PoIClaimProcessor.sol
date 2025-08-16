// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/MerklePatriciaTrie.sol";

interface ICollateralVault {
    function reimburseSlashedSRT(address user, uint256 amount) external;
    function reimburseSlashedUSDC(address user, uint256 amount) external;
}

contract PoIClaimProcessor is Ownable {
    using MerklePatriciaTrie for bytes;
    using MerklePatriciaTrie for bytes[];
    using RLPReader for RLPReader.RLPItem; // Adding this line for compilation

    address public collateralVault;

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

    mapping(address => uint256) public nextNonce;
    mapping(bytes32 => PoIClaim) public claims;
    mapping(bytes32 => bool) public isShardRootPublished;

    event PoIClaimSubmitted(address indexed user, bytes32 claimId);
    event PoIClaimVerified(bytes32 claimId, uint256 reimbursedAmount);
    event PoIClaimRejected(bytes32 claimId);
    event PoIClaimReimbursed(bytes32 claimId, uint256 reimbursedAmount);
    event RelayerReimbursed(address indexed relayer, uint256 amount);

    constructor(address _collateralVault) Ownable() {
        require(_collateralVault != address(0), "vault=0");
        collateralVault = _collateralVault;
    }

    function submitPoIClaim(bytes calldata claim, bytes memory signature) external {
        PoIClaim memory newClaim = abi.decode(claim, (PoIClaim));
        require(newClaim.nonce == nextNonce[newClaim.payer], "Invalid nonce");

        bytes32 claimHash = keccak256(claim);
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", claimHash));
        bytes32 r; bytes32 s; uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        if (v < 27) { v += 27; }
        address signer = ecrecover(messageHash, v, r, s);

        require(signer == newClaim.payer, "Invalid signature or payer address");
        require(claims[claimHash].payer == address(0), "Claim already submitted");

        newClaim.relayer = msg.sender;
        claims[claimHash] = newClaim;
        nextNonce[newClaim.payer]++;

        emit PoIClaimSubmitted(newClaim.payer, claimHash);
    }
    
    function verifyPoIClaim(bytes32 claimId) external onlyOwner {
        PoIClaim storage claim = claims[claimId];
        require(claim.payer != address(0), "Claim does not exist");
        require(!claim.isVerified, "Claim already verified");
        
        require(isShardRootPublished[claim.sourceShardRoot], "Source shard root not published");
        require(isShardRootPublished[claim.targetShardRoot], "Target shard root not published");

        bytes memory slashedTxHash = abi.encodePacked(keccak256(claim.slashedProof[0]));
        bytes memory nonArrivalTxHash = abi.encodePacked(keccak256(claim.nonArrivalProof[0]));

        bool isProofOfDepartureValid = MerklePatriciaTrie.verifyInclusion(claim.slashedProof, claim.sourceShardRoot, slashedTxHash, claim.slashedProof[0]);
        bool isProofOfNonArrivalValid = MerklePatriciaTrie.verifyNonInclusion(claim.nonArrivalProof, claim.targetShardRoot, nonArrivalTxHash);
        
        if (isProofOfDepartureValid && isProofOfNonArrivalValid) {
            claim.isVerified = true;
            emit PoIClaimVerified(claimId, claim.slashedAmount);
        } else {
            emit PoIClaimRejected(claimId);
        }
    }

    function publishShardRoot(bytes32 root) external onlyOwner {
        isShardRootPublished[root] = true;
    }

    function reimburseSlashedFunds(bytes32 claimId) external onlyOwner {
        PoIClaim storage claim = claims[claimId];
        require(claim.isVerified, "Claim not verified");
        require(!claim.isReimbursed, "Claim already reimbursed");

        if (claim.collateralToken == address(0)) {
            ICollateralVault(collateralVault).reimburseSlashedSRT(claim.payer, claim.slashedAmount);
        } else {
            ICollateralVault(collateralVault).reimburseSlashedUSDC(claim.payer, claim.slashedAmount);
        }
        
        claim.isReimbursed = true;
        emit PoIClaimReimbursed(claimId, claim.slashedAmount);
    }

    function relayerGasReimbursement(address relayer, uint256 amount) external onlyOwner {
        require(relayer != address(0), "Relayer address cannot be zero.");
        require(address(this).balance >= amount, "Insufficient contract balance for reimbursement.");
        
        (bool success, ) = relayer.call{value: amount}("");
        require(success, "Reimbursement failed.");

        emit RelayerReimbursed(relayer, amount);
    }

    receive() external payable {}
}
