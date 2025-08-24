// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// --- Interfaces ---
interface ICollateralVault {
    function lockSRT(address user, uint256 amount) external;

    function lockUSDC(address user, uint256 amount) external;

    function releaseSRT(address user, uint256 amount) external;

    function releaseUSDC(address user, uint256 amount) external;

    function slashSRT(address user, uint256 amount, address recipient) external;

    function slashUSDC(
        address user,
        uint256 amount,
        address recipient
    ) external;
}

interface IPoIClaimProcessor {
    function isPayoutAuthorized(bytes32 paymentId) external view returns (bool);
}

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

    uint256 public immutable usdcCollateralPercent;
    uint256 public immutable srtCollateralPercent;
    uint256 public immutable protocolFeePercent;
    uint256 public constant DISPUTE_TIMEOUT_BLOCKS = 21600; // ~72 hours
    uint256 public constant srtPrice = 0; // To be set later

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
     * @notice Initiates a payment by locking collateral and creating a dispute record.
     * @param recipient The address of the payment recipient.
     * @param amount The amount of USDC to be paid.
     * @param useSrtCollateral A boolean to determine whether to use SRT or USDC as collateral.
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
            "FS: Payment ID exists"
        );

        uint256 requiredCollateral;
        address collateralToken = useSrtCollateral
            ? address(srt)
            : address(usdc);

        if (useSrtCollateral) {
            requiredCollateral = (amount * srtCollateralPercent) / 100;
            collateralVault.lockSRT(msg.sender, requiredCollateral);
        } else {
            requiredCollateral = (amount * usdcCollateralPercent) / 100;
            collateralVault.lockUSDC(msg.sender, requiredCollateral);
        }

        disputes[paymentId] = Dispute({
            payer: msg.sender,
            recipient: recipient,
            collateralToken: collateralToken,
            paymentAmount: amount,
            collateralAmount: requiredCollateral,
            escrowBlock: block.number,
            status: Status.Pending
        });
        emit PaymentInitiated(paymentId, msg.sender, recipient, amount);
    }

    /**
     * @notice Executes a pending payment.
     * @param paymentId The ID of the payment to execute.
     */
    function executePayment(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(dispute.status == Status.Pending, "FS: Not a pending payment");

        bool success = usdc.transferFrom(
            dispute.payer,
            dispute.recipient,
            dispute.paymentAmount
        );

        if (success) {
            if (dispute.collateralToken == address(srt)) {
                collateralVault.releaseSRT(
                    dispute.payer,
                    dispute.collateralAmount
                );
            } else {
                collateralVault.releaseUSDC(
                    dispute.payer,
                    dispute.collateralAmount
                );
            }
            dispute.status = Status.Resolved;
            emit PaymentExecuted(paymentId);
        } else {
            collateralVault.slashUSDC(
                dispute.payer,
                dispute.collateralAmount,
                address(this)
            );
            dispute.status = Status.Failed;
            emit PaymentFailed(paymentId);
        }
    }

    /**
     * @notice Resolves a dispute after a watcher has submitted a valid proof of non-arrival.
     * @param paymentId The ID of the payment to resolve.
     */
    function resolveDispute(bytes32 paymentId) external nonReentrant onlyOwner {
        Dispute storage dispute = disputes[paymentId];
        require(dispute.status == Status.Failed, "FS: Dispute not failed");

        dispute.status = Status.Resolved;

        require(
            poiProcessor.isPayoutAuthorized(paymentId),
            "FS: Payout not authorized by PoI"
        );

        uint256 feeAmount = (dispute.paymentAmount * protocolFeePercent) / 100;
        uint256 recipientPayout = dispute.paymentAmount;
        uint256 payerRefund = dispute.collateralAmount -
            recipientPayout -
            feeAmount;

        IERC20(dispute.collateralToken).safeTransfer(
            dispute.recipient,
            recipientPayout
        );
        IERC20(dispute.collateralToken).safeTransfer(
            dispute.payer,
            payerRefund
        );
        IERC20(dispute.collateralToken).safeTransfer(owner(), feeAmount);

        emit DisputeResolved(paymentId, dispute.recipient);
    }

    /**
     * @notice Allows a payer to reclaim their collateral if a dispute times out.
     * @param paymentId The ID of the payment to claim.
     */
    function claimExpiredEscrow(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(dispute.payer == msg.sender, "FS: Not the payer");
        require(dispute.status == Status.Failed, "FS: Dispute not failed");
        require(
            block.number >= dispute.escrowBlock + DISPUTE_TIMEOUT_BLOCKS,
            "FS: Timeout not expired"
        );

        dispute.status = Status.Expired;

        IERC20(dispute.collateralToken).safeTransfer(
            dispute.payer,
            dispute.collateralAmount
        );
        emit EscrowClaimed(paymentId, dispute.payer);
    }
}
