// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";

contract PoIClaimProcessor is Ownable, EIP712 {
    struct Claim {
        address payer;
        address merchant;
        address collateralToken;
        uint256 slashedAmount;
        uint256 timestamp;
        uint256 nonce;
        bytes32 slashedTxDataHash;
        bytes32 slashedProofHash;
        bytes32 nonArrivalProofHash;
        bytes32 sourceShardRoot;
        bytes32 targetShardRoot;
        bool isVerified;
        bool isReimbursed;
        address relayer;
    }

    mapping(bytes32 => Claim) public claims;
    mapping(address => uint256) public nonces;
    mapping(bytes32 => bool) public publishedRoots;

    event PoIClaimSubmitted(address indexed payer, bytes32 indexed claimId);
    event PoIClaimVerified(bytes32 indexed claimId, uint256 slashedAmount);
    event PoIClaimReimbursed(bytes32 indexed claimId, uint256 slashedAmount);
    event ShardRootPublished(bytes32 indexed root);

    constructor() EIP712("SPP-PoIClaim", "1") {}

    function nextNonce(address payer) external view returns (uint256) {
        return nonces[payer];
    }

    function publishShardRoot(bytes32 root) external onlyOwner {
        publishedRoots[root] = true;
        emit ShardRootPublished(root);
    }

    function _hashClaim(
        address payer,
        address merchant,
        address collateralToken,
        uint256 slashedAmount,
        uint256 timestamp,
        uint256 nonce,
        bytes32 slashedTxDataHash,
        bytes32 slashedProofHash,
        bytes32 nonArrivalProofHash,
        bytes32 sourceShardRoot,
        bytes32 targetShardRoot
    ) internal view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256(
                            "Claim(address payer,address merchant,address collateralToken,uint256 slashedAmount,uint256 timestamp,uint256 nonce,bytes32 slashedTxDataHash,bytes32 slashedProofHash,bytes32 nonArrivalProofHash,bytes32 sourceShardRoot,bytes32 targetShardRoot)"
                        ),
                        payer,
                        merchant,
                        collateralToken,
                        slashedAmount,
                        timestamp,
                        nonce,
                        slashedTxDataHash,
                        slashedProofHash,
                        nonArrivalProofHash,
                        sourceShardRoot,
                        targetShardRoot
                    )
                )
            );
    }

    function _verify(
        bytes32 claimId,
        bytes memory signature
    ) internal pure returns (address) {
        return ECDSA.recover(claimId, signature);
    }

    function submitPoIClaim(
        address payer,
        address merchant,
        address collateralToken,
        uint256 slashedAmount,
        uint256 timestamp,
        uint256 nonce,
        bytes32 slashedTxDataHash,
        bytes32 slashedProofHash,
        bytes32 nonArrivalProofHash,
        bytes32 sourceShardRoot,
        bytes32 targetShardRoot,
        bytes calldata signature
    ) external {
        bytes32 claimId = _hashClaim(
            payer,
            merchant,
            collateralToken,
            slashedAmount,
            timestamp,
            nonce,
            slashedTxDataHash,
            slashedProofHash,
            nonArrivalProofHash,
            sourceShardRoot,
            targetShardRoot
        );
        require(
            claims[claimId].payer == address(0),
            "PoI: claim already submitted"
        );

        address recovered = _verify(claimId, signature);
        require(recovered == payer, "PoI: invalid signature");

        // ⭐ NOTE: This struct is intentionally declared without initialization
        // to avoid a "stack too deep" error. All fields are set immediately below.
        Claim memory newClaim;
        newClaim.payer = payer;
        newClaim.merchant = merchant;
        newClaim.collateralToken = collateralToken;
        newClaim.slashedAmount = slashedAmount;
        newClaim.timestamp = timestamp;
        newClaim.nonce = nonce;
        newClaim.slashedTxDataHash = slashedTxDataHash;
        newClaim.slashedProofHash = slashedProofHash;
        newClaim.nonArrivalProofHash = nonArrivalProofHash;
        newClaim.sourceShardRoot = sourceShardRoot;
        newClaim.targetShardRoot = targetShardRoot;
        newClaim.isVerified = false;
        newClaim.isReimbursed = false;
        newClaim.relayer = msg.sender;

        claims[claimId] = newClaim;

        nonces[payer]++;

        emit PoIClaimSubmitted(payer, claimId);
    }

    function verifyPoIClaim(bytes32 claimId) external onlyOwner {
        Claim storage c = claims[claimId];
        require(!c.isVerified, "PoI: already verified");
        require(
            publishedRoots[c.sourceShardRoot],
            "PoI: source root not published"
        );
        require(
            publishedRoots[c.targetShardRoot],
            "PoI: target root not published"
        );

        c.isVerified = true;
        emit PoIClaimVerified(claimId, c.slashedAmount);
    }

    function reimburseSlashedFunds(bytes32 claimId) external onlyOwner {
        Claim storage c = claims[claimId];
        require(c.isVerified, "PoI: claim not verified");
        require(!c.isReimbursed, "PoI: already reimbursed");

        c.isReimbursed = true;
        emit PoIClaimReimbursed(claimId, c.slashedAmount);
    }
}
