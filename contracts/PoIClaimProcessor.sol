// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/MerklePatriciaTrie.sol";

contract PoIClaimProcessor is Ownable {
    // --- State Variables ---

    // Mapping from a unique paymentId to its payout authorization status.
    mapping(bytes32 => bool) public isPayoutAuthorized;

    // Mapping of trusted shard roots submitted by the protocol owner/DAO.
    mapping(bytes32 => bool) public publishedRoots;

    // --- Events ---

    event PayoutAuthorized(bytes32 indexed paymentId);
    event ShardRootPublished(bytes32 indexed root);

    // --- Core Functions ---

    /**
     * @notice Processes a Merkle proof of non-inclusion to authorize a payout.
     * @param _paymentId The unique ID of the failed payment.
     * @param _targetShardRoot The root hash of the target shard's state trie.
     * @param _key The key (e.g., transaction hash) that should not be in the trie.
     * @param _proof The Merkle proof demonstrating the key's absence.
     * @dev Can be called by a watcher or the recipient to prove a transaction failed.
     */
    function processNonArrivalProof(
        bytes32 _paymentId,
        bytes32 _targetShardRoot,
        bytes calldata _key,
        bytes[] calldata _proof
    ) external {
        require(
            publishedRoots[_targetShardRoot],
            "PoI: Target root not published"
        );
        require(
            !isPayoutAuthorized[_paymentId],
            "PoI: Payout already authorized"
        );

        // The 'get' function from the MPT library will return an empty bytes array
        // if the key is not found in the trie, thus proving non-inclusion.
        bytes memory value = MerklePatriciaTrie.get(
            _proof,
            _targetShardRoot,
            _key
        );
        require(value.length == 0, "PoI: Key was found in the trie");

        isPayoutAuthorized[_paymentId] = true;
        emit PayoutAuthorized(_paymentId);
    }

    // --- Admin Functions ---

    /**
     * @notice Allows the owner to add a trusted shard root.
     * @param _root The 32-byte root hash of a shard's state trie.
     */
    function publishShardRoot(bytes32 _root) external onlyOwner {
        require(!publishedRoots[_root], "PoI: Root already published");
        publishedRoots[_root] = true;
        emit ShardRootPublished(_root);
    }
}