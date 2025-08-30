// contracts/PoIClaimProcessor.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PoIClaimProcessor (Simulation Stub)
 * @author FSP Architect
 * @notice This is a simplified version for simulation ONLY.
 * @dev It bypasses complex MPT proof verification but correctly tracks the
 * proof submitter's address to support the full economic model.
 * DO NOT USE IN PRODUCTION.
 */
contract PoIClaimProcessor is Ownable {
    // --- State Variables ---
    mapping(bytes32 => bool) public isPayoutAuthorized;
    // NEW: Tracks which address submitted the proof for a given payment ID.
    mapping(bytes32 => address) public proofSubmitter;

    // --- Events ---
    // MODIFIED: The event now includes the submitter's address.
    event PayoutAuthorized(
        bytes32 indexed paymentId,
        address indexed submitter
    );

    /**
     * @notice [SIMULATION STUB] Automatically authorizes a payout.
     * @dev Now tracks msg.sender as the proof submitter so they can be rewarded.
     * @param paymentId The unique ID of the failed payment.
     */
    function processNonArrivalProof(bytes32 paymentId) external {
        require(
            !isPayoutAuthorized[paymentId],
            "PoI: Payout already authorized"
        );

        // Mark the payout as authorized.
        isPayoutAuthorized[paymentId] = true;
        // Store the address of the watcher who called this function.
        proofSubmitter[paymentId] = msg.sender;

        emit PayoutAuthorized(paymentId, msg.sender);
    }

    /**
     * @notice NEW: A public getter function required by the FiniteSettlement contract.
     * @dev Allows the settlement contract to identify the proof submitter for
     * the distribution of the Proof Reward.
     * @param paymentId The ID of the payment.
     * @return The address of the watcher who submitted the proof.
     */
    function getProofSubmitter(
        bytes32 paymentId
    ) external view returns (address) {
        return proofSubmitter[paymentId];
    }
}
