// contracts/FiniteSettlement.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICollateralVault.sol";

// --- Interfaces ---
interface IPoIClaimProcessor {
    function isPayoutAuthorized(bytes32 paymentId) external view returns (bool);
}

/**
 * @title FiniteSettlement
 * @author FSP Architect
 * @notice The core logic contract for the Finite Settlement Protocol.
 * @dev This contract manages the lifecycle of a guaranteed payment. It handles
 * payment initiation, collateral locking, execution, and a dispute resolution
 * process for failed payments. It relies on a PoIClaimProcessor for proof
 * verification and a CollateralVault for fund management.
 */
contract FiniteSettlement is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Enums ---
    enum Status {
        Pending,
        Resolved,
        Failed,
        Expired
    }

    // --- State Variables ---
    ICollateralVault public immutable collateralVault;
    IPoIClaimProcessor public immutable poiProcessor;
    IERC20 public immutable usdc;
    IERC20 public immutable srt;

    /**
     * @dev Stores all data for a payment's dispute lifecycle.
     * @param payer The address initiating the payment and posting collateral.
     * @param recipient The intended recipient of the payment.
     * @param collateralToken The token used for collateral (SRT or USDC).
     * @param paymentAmount The amount of USDC to be paid.
     * @param collateralAmount The amount of collateral locked for the payment.
     * @param escrowBlock The block number when a payment failed and was escrowed.
     * @param status The current status of the payment/dispute.
     */
    struct Dispute {
        address payer;
        address recipient;
        address collateralToken;
        uint256 paymentAmount;
        uint256 collateralAmount;
        uint256 escrowBlock;
        Status status;
    }

    mapping(bytes32 => Dispute) public disputes;

    uint256 public constant DISPUTE_TIMEOUT_BLOCKS = 21600; // ~72 hours
    uint256 public immutable usdcCollateralPercent;
    uint256 public immutable srtCollateralPercent;
    uint256 public immutable protocolFeePercent;

    // --- Events ---
    event PaymentInitiated(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed recipient,
        uint256 amount
    );
    event PaymentExecuted(bytes32 indexed paymentId);
    event PaymentFailed(bytes32 indexed paymentId);
    event DisputeResolved(bytes32 indexed paymentId, address indexed winner);
    event EscrowClaimed(bytes32 indexed paymentId, address indexed payer);

    constructor(
        address vaultAddress,
        address poiAddress,
        address usdcAddress,
        address srtAddress
    ) {
        collateralVault = ICollateralVault(vaultAddress);
        poiProcessor = IPoIClaimProcessor(poiAddress);
        usdc = IERC20(usdcAddress);
        srt = IERC20(srtAddress);
        usdcCollateralPercent = 110;
        srtCollateralPercent = 125;
        protocolFeePercent = 1;
    }

    /**
     * @notice Initiates a payment by locking collateral in the vault.
     * @dev Creates a unique paymentId based on inputs and `block.timestamp`.
     * The use of timestamp here is for ID uniqueness, not for time-based logic,
     * and is safe from miner manipulation in this context.
     * @param recipient The address that will receive the payment.
     * @param amount The amount of USDC to be paid.
     * @param useSrtCollateral If true, lock SRT as collateral; otherwise, lock USDC.
     * @return paymentId The unique identifier for this payment.
     */
    function initiatePayment(
        address recipient,
        uint256 amount,
        bool useSrtCollateral
    ) external nonReentrant returns (bytes32 paymentId) {
        // --- CHECKS ---
        paymentId = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, recipient, amount)
        );
        require(disputes[paymentId].payer == address(0), "FS: Payment ID exists");

        uint256 requiredCollateral;
        address collateralToken = useSrtCollateral ? address(srt) : address(usdc);

        // --- EFFECTS ---
        disputes[paymentId] = Dispute({
            payer: msg.sender,
            recipient: recipient,
            collateralToken: collateralToken,
            paymentAmount: amount,
            collateralAmount: 0, 
            escrowBlock: 0, 
            status: Status.Pending
        });

        // --- INTERACTIONS ---
        if (useSrtCollateral) {
            requiredCollateral = (amount * srtCollateralPercent) / 100;
            disputes[paymentId].collateralAmount = requiredCollateral;
            collateralVault.lockSRT(msg.sender, requiredCollateral);
        } else {
            requiredCollateral = (amount * usdcCollateralPercent) / 100;
            disputes[paymentId].collateralAmount = requiredCollateral;
            collateralVault.lockUSDC(msg.sender, requiredCollateral);
        }
        
        emit PaymentInitiated(paymentId, msg.sender, recipient, amount);
    }
    
    /**
     * @notice Executes a successful payment.
     * @dev This function performs the USDC transfer from payer to recipient and
     * releases the payer's collateral. It follows the Checks-Effects-Interactions
     * pattern to prevent reentrancy.
     * The `usdc.safeTransferFrom` call uses `dispute.payer` as the `from` address.
     * This is secure because the `dispute.payer` is set to `msg.sender` in `initiatePayment`,
     * ensuring that only the original payer's funds can be moved, and only after they
     * have explicitly started the process.
     * @param paymentId The ID of the payment to execute.
     */
    function executePayment(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        
        // --- CHECKS ---
        require(dispute.status == Status.Pending, "FS: Not a pending payment");

        // --- EFFECTS ---
        dispute.status = Status.Resolved;

        // --- INTERACTIONS ---
        usdc.safeTransferFrom(
            dispute.payer,
            dispute.recipient,
            dispute.paymentAmount
        );

        if (dispute.collateralToken == address(srt)) {
            collateralVault.releaseSRT(dispute.payer, dispute.collateralAmount);
        } else {
            collateralVault.releaseUSDC(dispute.payer, dispute.collateralAmount);
        }

        emit PaymentExecuted(paymentId);
    }

    /**
     * @notice Handles a payment that has failed to execute off-chain.
     * @dev This function is called when a payment does not complete. It moves the
     * dispute to the 'Failed' state and slashes the payer's collateral, holding it
     * in escrow within this contract to await resolution.
     * @param paymentId The ID of the failed payment.
     */
    function handlePaymentFailure(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        
        // --- CHECKS ---
        require(dispute.status == Status.Pending, "FS: Not a pending payment");

        // --- EFFECTS ---
        dispute.status = Status.Failed;
        dispute.escrowBlock = block.number;

        // --- INTERACTIONS ---
        if (dispute.collateralToken == address(srt)) {
            collateralVault.slashSRT(
                dispute.payer,
                dispute.collateralAmount,
                address(this)
            );
        } else {
            collateralVault.slashUSDC(
                dispute.payer,
                dispute.collateralAmount,
                address(this)
            );
        }

        emit PaymentFailed(paymentId);
    }
    
    /**
     * @notice Resolves a failed dispute after a valid Proof of Inclusion is processed.
     * @dev Can only be called by the owner. It checks for authorization from the
     * PoIProcessor, then distributes the escrowed collateral: the payment amount
     * to the recipient, a protocol fee to the owner, and the remainder back to the payer.
     * @param paymentId The ID of the dispute to resolve.
     */
    function resolveDispute(
        bytes32 paymentId
    ) external nonReentrant onlyOwner {
        Dispute storage dispute = disputes[paymentId];

        // --- CHECKS ---
        require(dispute.status == Status.Failed, "FS: Dispute not failed");
        require(
            poiProcessor.isPayoutAuthorized(paymentId),
            "FS: Payout not authorized by PoI"
        );
        
        // --- EFFECTS ---
        dispute.status = Status.Resolved;

        // --- INTERACTIONS ---
        uint256 feeAmount = (dispute.paymentAmount * protocolFeePercent) / 100;
        uint256 recipientPayout = dispute.paymentAmount;
        uint256 payerRefund = dispute.collateralAmount -
            recipientPayout -
            feeAmount;

        IERC20(dispute.collateralToken).safeTransfer(
            dispute.recipient,
            recipientPayout
        );
        IERC20(dispute.collateralToken).safeTransfer(dispute.payer, payerRefund);
        IERC20(dispute.collateralToken).safeTransfer(owner(), feeAmount);

        emit DisputeResolved(paymentId, dispute.recipient);
    }

    /**
     * @notice Allows the payer to reclaim their full collateral if a dispute times out.
     * @dev This is a backstop mechanism. If a payment fails and no valid proof is
     * submitted within the `DISPUTE_TIMEOUT_BLOCKS` window, the original payer can
     * retrieve their collateral.
     * @param paymentId The ID of the expired dispute.
     */
    function claimExpiredEscrow(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        
        // --- CHECKS ---
        require(dispute.payer == msg.sender, "FS: Not the payer");
        require(dispute.status == Status.Failed, "FS: Dispute not failed");
        require(
            block.number >= dispute.escrowBlock + DISPUTE_TIMEOUT_BLOCKS,
            "FS: Timeout not expired"
        );
        
        // --- EFFECTS ---
        dispute.status = Status.Expired;

        // --- INTERACTIONS ---
        IERC20(dispute.collateralToken).safeTransfer(
            dispute.payer,
            dispute.collateralAmount
        );
        
        emit EscrowClaimed(paymentId, dispute.payer);
    }
}