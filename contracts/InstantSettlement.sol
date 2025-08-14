// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ICollateralVault {
    function usdcFreeOf(address user) external view returns (uint256);
    function lockUSDC(address user, uint256 amount) external;
    function releaseUSDC(address user, uint256 amount) external;
    function slashUSDC(address user, uint256 amount, address recipient) external;

    function srtFreeOf(address user) external view returns (uint256);
    function lockSRT(address user, uint256 amount) external;
    function releaseSRT(address user, uint256 amount) external;
    function slashSRT(address user, uint256 amount, address recipient) external;

    function srtStakeTimestamp(address user) external view returns (uint256);
}

contract InstantSettlement is Ownable {
    ICollateralVault public vault;
    IERC20 public usdc;
    IERC20 public srt;

    mapping(address => bool) public isMerchant;
    mapping(address => bool) public merchantInstantOnly;

    uint256 public softCap;
    uint256 public usdcCollateralPercent = 110;
    uint256 public initialSrtPercent = 150;
    uint256 public matureSrtPercent = 125;
    uint256 public srtMaturity = 30 days;
    uint256 public srtPrice;

    event MerchantRegistered(address indexed merchant, bool instantOnly);
    event MerchantUpdated(address indexed merchant, bool instantOnly);
    event SoftCapUpdated(uint256 newSoftCap);
    event SrtPriceUpdated(uint256 newPrice);
    event InstantPayment(address indexed payer, address indexed merchant, uint256 amountUSDC, address collateralToken, uint256 collateralAmount);
    event InstantPaymentFailed(address indexed payer, address indexed merchant, uint256 amountUSDC, address collateralToken, uint256 slashedCollateral);

    constructor(address _vault, address _usdc, address _srt, uint256 _softCap) Ownable() {
        require(_vault != address(0), "vault=0");
        require(_usdc != address(0), "usdc=0");
        require(_srt != address(0), "srt=0");

        vault = ICollateralVault(_vault);
        usdc = IERC20(_usdc);
        srt = IERC20(_srt);

        softCap = _softCap;
    }

    // -----------------------------
    // Admin configuration
    // -----------------------------

    function setSoftCap(uint256 _softCap) external onlyOwner {
        softCap = _softCap;
        emit SoftCapUpdated(_softCap);
    }

    function setSrtPrice(uint256 _srtPrice) external onlyOwner {
        // srtPrice is USD per SRT with 8 decimals (like many oracle feeds)
        srtPrice = _srtPrice;
        emit SrtPriceUpdated(_srtPrice);
    }

    function setSrtParams(uint256 _initialPercent, uint256 _maturePercent, uint256 _maturitySeconds) external onlyOwner {
        require(_initialPercent >= _maturePercent, "initial < mature");
        initialSrtPercent = _initialPercent;
        matureSrtPercent = _maturePercent;
        srtMaturity = _maturitySeconds;
    }

    function setUsdcCollateralPercent(uint256 _percent) external onlyOwner {
        require(_percent >= 100, "percent<100");
        usdcCollateralPercent = _percent;
    }

    // Merchant management
    function registerMerchant(address merchant, bool instantOnly) external onlyOwner {
        require(merchant != address(0), "merchant=0");
        isMerchant[merchant] = true;
        merchantInstantOnly[merchant] = instantOnly;
        emit MerchantRegistered(merchant, instantOnly);
    }

    function updateMerchant(address merchant, bool instantOnly) external onlyOwner {
        require(isMerchant[merchant], "not registered");
        merchantInstantOnly[merchant] = instantOnly;
        emit MerchantUpdated(merchant, instantOnly);
    }

    // -----------------------------
    // Core: Instant payment (USDC payments)
    // -----------------------------
    //
    // payer calls this to make an *instant* payment in USDC to `merchant`.
    // `collateralIsSRT` indicates whether the payer wants to back the payment
    // with SRT stake (true) or USDC stake (false).
    //
    // Pre-req: payer must have approved this contract (or the underlying transferFrom will be used).
    //
    function sendInstantPayment(address merchant, uint256 amountUSDC, bool collateralIsSRT) external {
        require(isMerchant[merchant], "recipient not merchant");
        require(amountUSDC > 0, "amount=0");
        require(amountUSDC <= softCap, "above soft cap");

        // If merchant is instant-only, then the merchant will only accept instant payments.
        // (This function is the instant path, so it's allowed.)
        // If merchant is not instant-only, they can accept slow payments as well (handled elsewhere).

        // Calculate required collateral (in appropriate token units)
        if (!collateralIsSRT) {
            // USDC collateral path: required = amountUSDC * usdcCollateralPercent / 100
            uint256 requiredUSDC = (amountUSDC * usdcCollateralPercent + 99) / 100; // round up
            // ensure payer has enough free USDC staked
            uint256 freeUSDC = vault.usdcFreeOf(msg.sender);
            require(freeUSDC >= requiredUSDC, "insufficient USDC collateral");

            // lock collateral
            vault.lockUSDC(msg.sender, requiredUSDC);

            // Attempt transfer of USDC payment from payer to merchant
            bool ok = usdc.transferFrom(msg.sender, merchant, amountUSDC);

            if (ok) {
                // success: release collateral
                vault.releaseUSDC(msg.sender, requiredUSDC);
                emit InstantPayment(msg.sender, merchant, amountUSDC, address(usdc), requiredUSDC);
            } else {
                // failure: slash collateral and pay merchant
                vault.slashUSDC(msg.sender, requiredUSDC, merchant);
                emit InstantPaymentFailed(msg.sender, merchant, amountUSDC, address(usdc), requiredUSDC);
            }
        } else {
            // SRT collateral path: compute required SRT units using srtPrice
            require(srtPrice > 0, "srtPrice not set");

            // choose percent based on stake age
            uint256 stakeTs = vault.srtStakeTimestamp(msg.sender);
            uint256 percent = initialSrtPercent;
            if (stakeTs > 0 && block.timestamp >= stakeTs + srtMaturity) {
                percent = matureSrtPercent;
            }

            // required SRT token units (18 decimals assumed for SRT)
            // Formula (derived):
            // requiredSRT_units = amountUSDC * percent * 1e20 / (100 * srtPrice)
            // where:
            // - amountUSDC is in USDC smallest units (6 decimals),
            // - srtPrice is USD per SRT with 8 decimals.
            uint256 numerator = amountUSDC * percent * (10**20);
            uint256 denominator = 100 * srtPrice;
            uint256 requiredSRT = (numerator + denominator - 1) / denominator; // round up

            uint256 freeSRT = vault.srtFreeOf(msg.sender);
            require(freeSRT >= requiredSRT, "insufficient SRT collateral");

            // lock SRT collateral
            vault.lockSRT(msg.sender, requiredSRT);

            // Attempt transfer of USDC payment from payer to merchant
            bool ok = usdc.transferFrom(msg.sender, merchant, amountUSDC);

            if (ok) {
                // success: release SRT collateral
                vault.releaseSRT(msg.sender, requiredSRT);
                emit InstantPayment(msg.sender, merchant, amountUSDC, address(srt), requiredSRT);
            } else {
                // failure: slash SRT collateral and pay merchant
                vault.slashSRT(msg.sender, requiredSRT, merchant);
                emit InstantPaymentFailed(msg.sender, merchant, amountUSDC, address(srt), requiredSRT);
            }
        }
    }

    // -----------------------------
    // Convenience / view helpers
    // -----------------------------

    function merchantIsInstantOnly(address merchant) external view returns (bool) {
        return merchantInstantOnly[merchant];
    }

    // Estimate required SRT units for an amountUSDC using current srtPrice and percent choice
    function estimateRequiredSRT(uint256 amountUSDC, bool useMaturePercent) external view returns (uint256) {
        require(srtPrice > 0, "srtPrice=0");
        uint256 percent = useMaturePercent ? matureSrtPercent : initialSrtPercent;
        uint256 numerator = amountUSDC * percent * (10**20);
        uint256 denominator = 100 * srtPrice;
        return (numerator + denominator - 1) / denominator;
    }
}