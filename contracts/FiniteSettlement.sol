// contracts/FiniteSettlement.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICollateralVault.sol";

interface IPoIClaimProcessor {
    function isPayoutAuthorized(bytes32 paymentId) external view returns (bool);

    function getProofSubmitter(
        bytes32 paymentId
    ) external view returns (address);
}

contract FiniteSettlement is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Pending,
        Resolved,
        Failed,
        Expired
    }

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
    ICollateralVault public immutable collateralVault;
    IPoIClaimProcessor public immutable poiProcessor;
    IERC20 public immutable usdc;
    IERC20 public immutable srt;

    uint256 public constant DISPUTE_TIMEOUT_BLOCKS = 21600;
    uint256 public immutable usdcCollateralPercent;
    uint256 public immutable srtCollateralPercent;
    uint256 public immutable protocolFeePercent;
    uint256 public immutable watcherRewardPercent;

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
        watcherRewardPercent = 20;
    }

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

    function executePayment(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(dispute.status == Status.Pending, "FS: Not a pending payment");
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

    function handlePaymentFailure(bytes32 paymentId) external nonReentrant {
        Dispute storage dispute = disputes[paymentId];
        require(dispute.status == Status.Pending, "FS: Not a pending payment");
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
     * @dev The onlyOwner modifier has been removed to allow for an automated, permissionless system.
     */
    function resolveDispute(bytes32 paymentId) external nonReentrant {
        // MODIFIED: `onlyOwner` modifier removed.
        Dispute storage dispute = disputes[paymentId];
        require(dispute.status == Status.Failed, "FS: Dispute not failed");
        require(
            poiProcessor.isPayoutAuthorized(paymentId),
            "FS: Payout not authorized by PoI"
        );

        dispute.status = Status.Resolved;

        address proofSubmitter = poiProcessor.getProofSubmitter(paymentId);
        require(
            proofSubmitter != address(0),
            "FS: Submitter cannot be zero address"
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

        emit DisputeResolved(paymentId, dispute.recipient);
    }

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
