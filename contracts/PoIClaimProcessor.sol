// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/MerklePatriciaTrie.sol";

contract PoIClaimProcessor is Ownable {
    // --- State Variables ---
    mapping(bytes32 => bool) public isPayoutAuthorized;
    mapping(bytes32 => bool) public publishedRoots;

    // --- Events ---
    event PayoutAuthorized(bytes32 indexed paymentId);
    event ShardRootPublished(bytes32 indexed root);

    // --- Core Functions ---
    /**
     * @notice Processes a Merkle proof of non-inclusion to authorize a payout.
     * @param paymentId The unique ID of the failed payment.
     * @param targetShardRoot The root hash of the target shard's state trie.
     * @param key The key (e.g., transaction hash) that should not be in the trie.
     * @param proof The Merkle proof demonstrating the key's absence.
     */
    function processNonArrivalProof(
        bytes32 paymentId, // ⭐ FIX: Renamed
        bytes32 targetShardRoot, // ⭐ FIX: Renamed
        bytes calldata key, // ⭐ FIX: Renamed
        bytes[] calldata proof // ⭐ FIX: Renamed
    ) external {
        require(
            publishedRoots[targetShardRoot],
            "PoI: Target root not published"
        );
        require(
            !isPayoutAuthorized[paymentId],
            "PoI: Payout already authorized"
        );
        bytes memory value = MerklePatriciaTrie.get(
            proof,
            targetShardRoot,
            key
        );
        require(value.length == 0, "PoI: Key was found in the trie");

        isPayoutAuthorized[paymentId] = true;
        emit PayoutAuthorized(paymentId);
    }

    // --- Admin Functions ---
    /**
     * @notice Allows the owner to add a trusted shard root.
     * @param root The 32-byte root hash of a shard's state trie.
     */
    function publishShardRoot(bytes32 root) external onlyOwner {
        require(!publishedRoots[root], "PoI: Root already published");
        publishedRoots[root] = true;
        emit ShardRootPublished(root);
    }
}
