// contracts/FiniteSettlement.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICollateralVault.sol";

/**
 * @title IPoIClaimProcessor
 * @notice The interface for the Proof of Inclusion Claim Processor contract.
 * @dev This interface defines the functions the FiniteSettlement contract needs to
 * verify dispute resolutions and identify the watcher eligible for a reward.
 */
interface IPoIClaimProcessor {
    function isPayoutAuthorized(bytes32 paymentId) external view returns (bool);

    function getProofSubmitter(
        bytes32 paymentId
    ) external view returns (address);
}

/**
 * @title FiniteSettlement
 * @author FSP Architect
 * @notice The core logic contract for the Finite Settlement Protocol.
 * @dev This contract manages the lifecycle of a guaranteed payment. It handles
 * payment initiation, collateral locking, execution, and a permissionless dispute resolution
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

    // --- Structs ---
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

    // --- State Variables ---
    mapping(bytes32 => Dispute) public disputes;
    ICollateralVault public immutable collateralVault;
    IPoIClaimProcessor public immutable poiProcessor;
    IERC20 public immutable usdc;
    IERC20 public immutable srt;

    // --- Protocol Parameters ---
    /// @notice The number of blocks after a payment fails before the payer can reclaim their collateral.
    uint256 public constant DISPUTE_TIMEOUT_BLOCKS = 21600; // ~3 days on Arbitrum
    /// @notice The collateral percentage required when using USDC (e.g., 110 = 110%).
    uint256 public immutable usdcCollateralPercent;
    /// @notice The collateral percentage required when using SRT (e.g., 125 = 125%).
    uint256 public immutable srtCollateralPercent;
    /// @notice The total fee taken during a dispute, as a percentage of the payment amount (e.g., 1 = 1%).
    uint256 public immutable protocolFeePercent;
    /// @notice The percentage of the total protocol fee that is paid to the watcher as a Proof Reward (e.g., 20 = 20%).
    uint256 public immutable watcherRewardPercent;

    // --- Events ---
    event PaymentInitiated(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed recipient,
        uint256 amount
    );
    event PaymentExecuted(bytes32 indexed paymentId);
    event PaymentFailed(bytes32 indexed paymentId);
    event DisputeResolved(
        bytes32 indexed paymentId,
        address indexed winner,
        address indexed proofSubmitter
    );
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
        watcherRewardPercent = 20;
    }

    /**
     * @notice Initiates a payment by locking collateral in the vault.
     * @dev Creates a unique paymentId using a hash of inputs including `block.timestamp`.
     * This use of timestamp is safe for uniqueness as it's not used for time-based logic.
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
        paymentId = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, recipient, amount)
        );
        require(
            disputes[paymentId].payer == address(0),
            "FiniteSettlement: Payment ID exists"
        );

        uint256 requiredCollateral;
        address collateralToken = useSrtCollateral
            ? address(srt)
            : address(usdc);

        disputes[paymentId] = Dispute({
            payer: msg.sender,
            recipient: recipient,
            collateralToken: collateralToken,
            paymentAmount: amount,
            collateralAmount: 0,
            escrowBlock: 0,
            status: Status.Pending
        });

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
     * @notice Executes a successful payment, transferring USDC and releasing collateral.
     * @dev Follows the Checks-Effects-Interactions pattern to prevent re-entrancy.
     * @param paymentId The ID of the payment to execute.
     */
    function executePayment(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(
            dispute.status == Status.Pending,
            "FiniteSettlement: Not a pending payment"
        );
        dispute.status = Status.Resolved;
        usdc.safeTransferFrom(
            dispute.payer,
            dispute.recipient,
            dispute.paymentAmount
        );

        if (dispute.collateralToken == address(srt)) {
            collateralVault.releaseSRT(dispute.payer, dispute.collateralAmount);
        } else {
            collateralVault.releaseUSDC(
                dispute.payer,
                dispute.collateralAmount
            );
        }

        emit PaymentExecuted(paymentId);
    }

    /**
     * @notice Handles a payment that has failed, moving it to a dispute state.
     * @dev This function slashes the payer's collateral and holds it in escrow within
     * this contract to await a dispute resolution.
     * @param paymentId The ID of the failed payment.
     */
    function handlePaymentFailure(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(
            dispute.status == Status.Pending,
            "FiniteSettlement: Not a pending payment"
        );
        dispute.status = Status.Failed;
        dispute.escrowBlock = block.number;

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
     * @notice [PERMISSIONLESS] Resolves a failed dispute after a payout has been authorized.
     * @dev This function can be called by anyone (e.g., the watcher who submitted the proof)
     * to trigger the final distribution of funds. It is protected by the isPayoutAuthorized check.
     * It splits the protocol fee, rewarding the watcher and sending the rest to the treasury (owner).
     * @param paymentId The ID of the dispute to resolve.
     */
    function resolveDispute(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(
            dispute.status == Status.Failed,
            "FiniteSettlement: Dispute not failed"
        );
        require(
            poiProcessor.isPayoutAuthorized(paymentId),
            "FiniteSettlement: Payout not authorized by PoI"
        );

        dispute.status = Status.Resolved;

        address proofSubmitter = poiProcessor.getProofSubmitter(paymentId);
        require(
            proofSubmitter != address(0),
            "FiniteSettlement: Submitter cannot be zero address"
        );

        uint256 totalFeeAmount = (dispute.paymentAmount * protocolFeePercent) /
            100;
        uint256 watcherPayout = (totalFeeAmount * watcherRewardPercent) / 100;
        uint256 treasuryPayout = totalFeeAmount - watcherPayout;

        uint256 recipientPayout = dispute.paymentAmount;
        uint256 payerRefund = dispute.collateralAmount -
            recipientPayout -
            totalFeeAmount;

        IERC20 token = IERC20(dispute.collateralToken);
        token.safeTransfer(dispute.recipient, recipientPayout);
        token.safeTransfer(dispute.payer, payerRefund);
        token.safeTransfer(proofSubmitter, watcherPayout);
        token.safeTransfer(owner(), treasuryPayout);

        emit DisputeResolved(paymentId, dispute.recipient, proofSubmitter);
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
        require(dispute.payer == msg.sender, "FiniteSettlement: Not the payer");
        require(
            dispute.status == Status.Failed,
            "FiniteSettlement: Dispute not failed"
        );
        require(
            block.number >= dispute.escrowBlock + DISPUTE_TIMEOUT_BLOCKS,
            "FiniteSettlement: Timeout not expired"
        );

        dispute.status = Status.Expired;

        IERC20(dispute.collateralToken).safeTransfer(
            dispute.payer,
            dispute.collateralAmount
        );

        emit EscrowClaimed(paymentId, dispute.payer);
    }
}
