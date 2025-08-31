// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./CollateralVault.sol";

/**
 * @title Instant Settlement Contract
 * @notice This contract facilitates instant, over-collateralized payments to registered merchants.
 * It interacts with a CollateralVault to lock and slash collateral, ensuring merchants are always paid.
 */
interface ICollateralVault {
    function usdcFreeOf(address user) external view returns (uint256);

    function lockUSDC(address user, uint256 amount) external;

    function releaseUSDC(address user, uint256 amount) external;

    function slashUSDC(
        address user,
        uint256 amount,
        address recipient
    ) external;

    function srtFreeOf(address user) external view returns (uint256);

    function lockSRT(address user, uint256 amount) external;

    function releaseSRT(address user, uint256 amount) external;

    function slashSRT(address user, uint256 amount, address recipient) external;

    function srtStakeTimestamp(address user) external view returns (uint256);
}

contract InstantSettlement is Ownable, ReentrancyGuard {
    // --- Core Contract Connections ---
    ICollateralVault public immutable vault;
    IERC20 public immutable usdc;
    IERC20 public immutable srt;

    // --- State Variables ---
    mapping(address => bool) public isMerchant;
    mapping(address => bool) public merchantInstantOnly;
    uint256 public softCap; // The maximum amount for a single instant payment.
    uint256 public srtPrice; // The price of SRT in USD, with 8 decimals.

    // --- Collateralization Parameters ---
    uint256 public usdcCollateralPercent = 110; // 110% for USDC collateral
    uint256 public initialSrtPercent = 150; // 150% for new SRT stakes (<30 days)
    uint256 public matureSrtPercent = 125; // 125% for mature SRT stakes (>30 days)
    uint256 public srtMaturity = 30 days;

    // --- Events ---
    event MerchantRegistered(address indexed merchant, bool instantOnly);
    event MerchantUpdated(address indexed merchant, bool instantOnly);
    event SoftCapUpdated(uint256 newSoftCap);
    event SrtPriceUpdated(uint256 newPrice);
    event SrtParamsUpdated(
        uint256 initialPercent,
        uint256 maturePercent,
        uint256 maturitySeconds
    );
    event UsdcCollateralPercentUpdated(uint256 percent);
    event InstantPayment(
        address indexed payer,
        address indexed merchant,
        uint256 amountUSDC,
        address collateralToken,
        uint256 collateralAmount
    );
    event InstantPaymentFailed(
        address indexed payer,
        address indexed merchant,
        uint256 amountUSDC,
        address collateralToken,
        uint256 slashedCollateral
    );

    /**
     * @notice Sets up the contract with immutable addresses and initial parameters.
     */
    constructor(address _vault, address _usdc, address _srt, uint256 _softCap) {
        require(_vault != address(0), "vault=0");
        require(_usdc != address(0), "usdc=0");
        require(_srt != address(0), "srt=0");

        vault = ICollateralVault(_vault);
        usdc = IERC20(_usdc);
        srt = IERC20(_srt);
        softCap = _softCap;
    }

    // --- Admin Configuration ---

    /**
     * @notice Updates the soft cap for a single instant payment.
     * @param _softCap The new maximum payment amount in USDC units.
     */
    function setSoftCap(uint256 _softCap) external onlyOwner {
        softCap = _softCap;
        emit SoftCapUpdated(_softCap);
    }

    /**
     * @notice Updates the price of the SRT token, used for collateral calculations.
     * @param _srtPrice The price of 1 SRT in USD, formatted with 8 decimals.
     */
    function setSrtPrice(uint256 _srtPrice) external onlyOwner {
        srtPrice = _srtPrice;
        emit SrtPriceUpdated(_srtPrice);
    }

    /**
     * @notice Updates the dynamic collateralization parameters for SRT.
     * @param _initialPercent The new percentage for initial stakes.
     * @param _maturePercent The new percentage for mature stakes.
     * @param _maturitySeconds The new duration for a stake to be considered mature.
     */
    function setSrtParams(
        uint256 _initialPercent,
        uint256 _maturePercent,
        uint256 _maturitySeconds
    ) external onlyOwner {
        require(_initialPercent >= _maturePercent, "initial < mature");
        initialSrtPercent = _initialPercent;
        matureSrtPercent = _maturePercent;
        srtMaturity = _maturitySeconds;
        emit SrtParamsUpdated(
            _initialPercent,
            _maturePercent,
            _maturitySeconds
        );
    }

    /**
     * @notice Updates the collateralization percentage for USDC.
     * @param _percent The new collateralization percentage (e.g., 110 for 110%).
     */
    function setUsdcCollateralPercent(uint256 _percent) external onlyOwner {
        require(_percent >= 100, "percent<100");
        usdcCollateralPercent = _percent;
        emit UsdcCollateralPercentUpdated(_percent);
    }

    // --- Merchant Management ---

    /**
     * @notice Registers a new merchant address.
     * @param merchant The address of the merchant to register.
     * @param instantOnly A flag to indicate if the merchant only accepts instant payments.
     */
    function registerMerchant(
        address merchant,
        bool instantOnly
    ) external onlyOwner {
        require(merchant != address(0), "merchant=0");
        isMerchant[merchant] = true;
        merchantInstantOnly[merchant] = instantOnly;
        emit MerchantRegistered(merchant, instantOnly);
    }

    /**
     * @notice Updates an existing merchant's settings.
     * @param merchant The address of the merchant to update.
     * @param instantOnly The new value for the instant-only flag.
     */
    function updateMerchant(
        address merchant,
        bool instantOnly
    ) external onlyOwner {
        require(isMerchant[merchant], "not registered");
        merchantInstantOnly[merchant] = instantOnly;
        emit MerchantUpdated(merchant, instantOnly);
    }

    // --- Core Payment Logic ---

    /**
     * @notice Executes an instant payment from a user to a merchant, backed by collateral.
     * @dev Locks collateral, attempts payment, then releases or slashes based on the outcome.
     * @param merchant The recipient merchant's address.
     * @param amountUSDC The amount of USDC to be paid.
     * @param collateralIsSRT True if using SRT for collateral, false if using USDC.
     */
    function sendInstantPayment(
        address merchant,
        uint256 amountUSDC,
        bool collateralIsSRT
    ) external nonReentrant {
        require(isMerchant[merchant], "recipient not merchant");
        require(amountUSDC > 0, "amount=0");
        require(amountUSDC <= softCap, "above soft cap");
        require(merchantInstantOnly[merchant], "merchant not instant-only");

        if (!collateralIsSRT) {
            uint256 requiredUSDC = (amountUSDC * usdcCollateralPercent + 99) /
                100;
            require(
                vault.usdcFreeOf(msg.sender) >= requiredUSDC,
                "insufficient USDC collateral"
            );

            vault.lockUSDC(msg.sender, requiredUSDC);
            bool ok = usdc.transferFrom(msg.sender, merchant, amountUSDC);

            if (ok) {
                vault.releaseUSDC(msg.sender, requiredUSDC);
                emit InstantPayment(
                    msg.sender,
                    merchant,
                    amountUSDC,
                    address(usdc),
                    requiredUSDC
                );
            } else {
                vault.slashUSDC(msg.sender, requiredUSDC, merchant);
                emit InstantPaymentFailed(
                    msg.sender,
                    merchant,
                    amountUSDC,
                    address(usdc),
                    requiredUSDC
                );
            }
        } else {
            require(srtPrice > 0, "srtPrice not set");

            uint256 stakeTs = vault.srtStakeTimestamp(msg.sender);
            uint256 percent = (stakeTs > 0 &&
                block.timestamp >= stakeTs + srtMaturity)
                ? matureSrtPercent
                : initialSrtPercent;

            // This calculation is more robust against precision loss with large numbers.
            uint256 numerator = amountUSDC * percent * 1e20; // Scale up for precision
            uint256 denominator = 100 * srtPrice; // srtPrice has 8 decimals
            uint256 requiredSRT = (numerator + denominator - 1) / denominator;

            require(
                vault.srtFreeOf(msg.sender) >= requiredSRT,
                "insufficient SRT collateral"
            );

            vault.lockSRT(msg.sender, requiredSRT);
            bool ok = usdc.transferFrom(msg.sender, merchant, amountUSDC);

            if (ok) {
                vault.releaseSRT(msg.sender, requiredSRT);
                emit InstantPayment(
                    msg.sender,
                    merchant,
                    amountUSDC,
                    address(srt),
                    requiredSRT
                );
            } else {
                vault.slashSRT(msg.sender, requiredSRT, merchant);
                emit InstantPaymentFailed(
                    msg.sender,
                    merchant,
                    amountUSDC,
                    address(srt),
                    requiredSRT
                );
            }
        }
    }

    // --- View Helpers ---

    /**
     * @notice Checks if a merchant is flagged as instant-only.
     * @return True if the merchant only accepts instant payments, false otherwise.
     */
    function merchantIsInstantOnly(
        address merchant
    ) external view returns (bool) {
        return merchantInstantOnly[merchant];
    }

    /**
     * @notice Estimates the amount of SRT required to collateralize a given USDC payment.
     * @param amountUSDC The amount of the payment in USDC units.
     * @param useMaturePercent True to use the mature stake rate, false to use the initial rate.
     * @return The estimated amount of SRT required (in wei).
     */
    function estimateRequiredSRT(
        uint256 amountUSDC,
        bool useMaturePercent
    ) external view returns (uint256) {
        require(srtPrice > 0, "srtPrice=0");
        uint256 percent = useMaturePercent
            ? matureSrtPercent
            : initialSrtPercent;

        uint256 numerator = amountUSDC * percent * 1e20;
        uint256 denominator = 100 * srtPrice;
        return (numerator + denominator - 1) / denominator;
    }
}
