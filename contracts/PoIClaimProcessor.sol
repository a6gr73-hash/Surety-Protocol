// contracts/PoIClaimProcessor.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
// MODIFIED: Corrected the import path to the new 'optimism' subdirectory.
import "./libraries/optimism/MerkleTrie.sol";

/**
 * @title PoIClaimProcessor
 * @author FSP Architect
 * @notice Verifies proofs of non-arrival for the Finite Settlement Protocol.
 * @dev This contract is responsible for verifying Merkle Patricia Trie proofs to
 * confirm that a transaction did not occur on a target layer. It uses a battle-tested
 * MPT library sourced from Optimism for security and reliability. The key provided
 * to this contract should already be hashed, as it bypasses the SecureMerkleTrie wrapper.
 */
contract PoIClaimProcessor is Ownable {
    // --- State Variables ---

    /// @notice A mapping of payment IDs to their authorization status. True if a valid proof has been processed.
    mapping(bytes32 => bool) public isPayoutAuthorized;
    /// @notice A mapping of payment IDs to the address that submitted the valid proof.
    mapping(bytes32 => address) public proofSubmitter;
    /// @notice A whitelist of trusted state roots that proofs can be verified against.
    mapping(bytes32 => bool) public publishedRoots;

    // --- Events ---

    event ShardRootPublished(bytes32 indexed root);
    event PayoutAuthorized(
        bytes32 indexed paymentId,
        address indexed submitter
    );

    /**
     * @notice Verifies a non-inclusion proof and authorizes a payout if valid.
     * @dev A watcher calls this function to prove a transaction key is not included in a
     * given state root. A successful verification allows the FiniteSettlement
     * contract to resolve the dispute.
     * @param paymentId The unique ID of the failed payment.
     * @param targetShardRoot The root hash of the target shard's state trie.
     * @param key The hashed key that should not be in the trie.
     * @param proof The Merkle proof demonstrating the key's absence.
     */
    function processNonArrivalProof(
        bytes32 paymentId,
        bytes32 targetShardRoot,
        bytes calldata key,
        bytes[] calldata proof
    ) external {
        require(
            publishedRoots[targetShardRoot],
            "PoI: Target root not published"
        );
        require(
            !isPayoutAuthorized[paymentId],
            "PoI: Payout already authorized"
        );

        // The core security check: use the adapted MPT library to verify the proof.
        bytes memory value = MerkleTrie.get(key, proof, targetShardRoot);

        // A non-inclusion proof is valid if the returned value is empty bytes.
        require(
            value.length == 0,
            "PoI: Key was found in the trie (inclusion proof provided)"
        );

        isPayoutAuthorized[paymentId] = true;
        proofSubmitter[paymentId] = msg.sender;
        emit PayoutAuthorized(paymentId, msg.sender);
    }

    /**
     * @notice Allows the owner to publish a trusted state root.
     * @dev This is a privileged action that adds a state root to the whitelist,
     * enabling proofs to be verified against it.
     * @param root The 32-byte root hash of a shard's state trie.
     */
    function publishShardRoot(bytes32 root) external onlyOwner {
        require(!publishedRoots[root], "PoI: Root already published");
        publishedRoots[root] = true;
        emit ShardRootPublished(root);
    }

    /**
     * @notice Public getter to allow the settlement contract to identify the proof submitter.
     * @dev This is called by the FiniteSettlement contract during dispute resolution
     * to determine who receives the Proof Reward.
     * @param paymentId The ID of the payment.
     * @return The address of the watcher who submitted the proof.
     */
    function getProofSubmitter(
        bytes32 paymentId
    ) external view returns (address) {
        return proofSubmitter[paymentId];
    }
}
