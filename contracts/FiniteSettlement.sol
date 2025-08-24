// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./libraries/MerklePatriciaTrie.sol";

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
        bool resolved;
    }

    mapping(bytes32 => Dispute) public disputes;

    uint256 public usdcCollateralPercent;
    uint256 public srtCollateralPercent;
    uint256 public srtPrice;
    uint256 public protocolFeePercent;
    uint256 public constant DISPUTE_TIMEOUT_BLOCKS = 21600; // ~72 hours

    // --- Events ---
    event PaymentInitiated(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed recipient,
        uint256 amount
    );
    event PaymentSucceeded(bytes32 indexed paymentId);
    event DisputeCreated(bytes32 indexed paymentId, uint256 collateralAmount);
    event DisputeResolved(bytes32 indexed paymentId, address indexed winner);
    event EscrowClaimed(bytes32 indexed paymentId, address indexed payer);

    constructor(
        address _vaultAddress,
        address _poiAddress,
        address _usdcAddress,
        address _srtAddress
    ) {
        collateralVault = ICollateralVault(_vaultAddress);
        poiProcessor = IPoIClaimProcessor(_poiAddress);
        usdc = IERC20(_usdcAddress);
        srt = IERC20(_srtAddress);

        usdcCollateralPercent = 110;
        srtCollateralPercent = 125;
        protocolFeePercent = 1;
    }

    function initiatePayment(
        address _recipient,
        uint256 _amount,
        bool _useSrtCollateral
    ) external nonReentrant returns (bytes32 paymentId) {
        paymentId = keccak256(
            abi.encodePacked(block.timestamp, msg.sender, _recipient, _amount)
        );
        emit PaymentInitiated(paymentId, msg.sender, _recipient, _amount);

        uint256 requiredCollateral;
        address collateralToken = _useSrtCollateral
            ? address(srt)
            : address(usdc);

        // ⭐ 1. Lock the appropriate collateral in the Vault
        if (_useSrtCollateral) {
            requiredCollateral = (_amount * srtCollateralPercent) / 100;
            collateralVault.lockSRT(msg.sender, requiredCollateral);
        } else {
            requiredCollateral = (_amount * usdcCollateralPercent) / 100;
            collateralVault.lockUSDC(msg.sender, requiredCollateral);
        }

        // ⭐ 2. Attempt the USDC payment
        bool success = usdc.transferFrom(msg.sender, _recipient, _amount);
        if (success) {
            // ⭐ 3. On success, release the collateral back to the payer
            if (_useSrtCollateral) {
                collateralVault.releaseSRT(msg.sender, requiredCollateral);
            } else {
                collateralVault.releaseUSDC(msg.sender, requiredCollateral);
            }
            emit PaymentSucceeded(paymentId);
        } else {
            // ⭐ 4. On failure, slash the collateral to this contract (the escrow)
            if (_useSrtCollateral) {
                collateralVault.slashSRT(
                    msg.sender,
                    requiredCollateral,
                    address(this)
                );
            } else {
                collateralVault.slashUSDC(
                    msg.sender,
                    requiredCollateral,
                    address(this)
                );
            }

            // ⭐ 5. Create a dispute record
            disputes[paymentId] = Dispute({
                payer: msg.sender,
                recipient: _recipient,
                collateralToken: collateralToken,
                paymentAmount: _amount,
                collateralAmount: requiredCollateral,
                escrowBlock: block.number,
                resolved: false
            });
            emit DisputeCreated(paymentId, requiredCollateral);
        }
    }

    /**
     * @notice Resolves a dispute after a watcher has submitted a valid proof of non-arrival.
     * @param _paymentId The ID of the payment to resolve.
     * @dev For this phase, this function is owner-only for security.
     */
    function resolveDispute(
        bytes32 _paymentId
    ) external nonReentrant onlyOwner {
        Dispute storage dispute = disputes[_paymentId];
        require(dispute.escrowBlock > 0, "FS: Dispute does not exist");
        require(!dispute.resolved, "FS: Dispute already resolved");

        // ⭐ FIX: Update state before external calls to prevent reentrancy
        dispute.resolved = true;

        require(
            poiProcessor.isPayoutAuthorized(_paymentId),
            "FS: Payout not authorized by PoI"
        );

        uint256 feeAmount = (dispute.paymentAmount * protocolFeePercent) / 100;
        uint256 recipientPayout = dispute.paymentAmount;
        uint256 payerRefund = dispute.collateralAmount -
            recipientPayout -
            feeAmount;

        // ⭐ FIX: Use SafeERC20 helpers for secure transfers
        IERC20(dispute.collateralToken).safeTransfer(
            dispute.recipient,
            recipientPayout
        );
        IERC20(dispute.collateralToken).safeTransfer(
            dispute.payer,
            payerRefund
        );
        IERC20(dispute.collateralToken).safeTransfer(owner(), feeAmount);

        emit DisputeResolved(_paymentId, dispute.recipient);
    }

    /**
     * @notice Allows a payer to reclaim their collateral if a dispute times out.
     * @param _paymentId The ID of the payment to claim.
     */
    function claimExpiredEscrow(bytes32 _paymentId) external nonReentrant {
        Dispute storage dispute = disputes[_paymentId];
        require(dispute.payer == msg.sender, "FS: Not the payer");
        require(dispute.escrowBlock > 0, "FS: Dispute does not exist");
        require(!dispute.resolved, "FS: Dispute already resolved");
        require(
            block.number >= dispute.escrowBlock + DISPUTE_TIMEOUT_BLOCKS,
            "FS: Timeout not expired"
        );

        // ⭐ FIX: Update state before external calls to prevent reentrancy
        dispute.resolved = true;

        // ⭐ FIX: Use SafeERC20 helpers for secure transfers
        IERC20(dispute.collateralToken).safeTransfer(
            dispute.payer,
            dispute.collateralAmount
        );
        emit EscrowClaimed(_paymentId, dispute.payer);
    }
}