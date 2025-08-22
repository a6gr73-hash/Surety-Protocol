// contracts/InstantSettlement.sol

// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./CollateralVault.sol";

// ⭐ FIX: Updated interface to use srtStakeBlockNumber
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

    function srtStakeBlockNumber(address user) external view returns (uint256);
}

contract InstantSettlement is Ownable, ReentrancyGuard {
    ICollateralVault public immutable vault;
    IERC20 public immutable usdc;
    IERC20 public immutable srt;

    mapping(address => bool) public isMerchant;
    mapping(address => bool) public merchantInstantOnly;

    uint256 public softCap;
    uint256 public usdcCollateralPercent = 110;
    uint256 public initialSrtPercent = 150;
    uint256 public matureSrtPercent = 125;
    // ⭐ FIX: Switched from a time duration to a block duration. Assumes ~12s block time.
    // (30 days * 24 hours * 60 mins * 60 secs) / 12 secs/block = 216,000 blocks
    uint256 public srtMaturityBlocks = 216000;
    uint256 public srtPrice;

    event MerchantRegistered(address indexed merchant, bool instantOnly);
    event MerchantUpdated(address indexed merchant, bool instantOnly);
    event SoftCapUpdated(uint256 newSoftCap);
    event SrtPriceUpdated(uint256 newPrice);
    // ⭐ FIX: Updated event to use blocks instead of seconds
    event SrtParamsUpdated(
        uint256 initialPercent,
        uint256 maturePercent,
        uint256 maturityBlocks
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

    constructor(
        address _vault,
        address _usdc,
        address _srt,
        uint256 _softCap
    ) Ownable() {
        require(_vault != address(0), "vault=0");
        require(_usdc != address(0), "usdc=0");
        require(_srt != address(0), "srt=0");

        vault = ICollateralVault(_vault);
        usdc = IERC20(_usdc);
        srt = IERC20(_srt);

        softCap = _softCap;
    }

    function setSoftCap(uint256 _softCap) external onlyOwner {
        softCap = _softCap;
        emit SoftCapUpdated(_softCap);
    }

    function setSrtPrice(uint256 _srtPrice) external onlyOwner {
        srtPrice = _srtPrice;
        emit SrtPriceUpdated(_srtPrice);
    }

    // ⭐ FIX: Updated function signature and logic to use blocks
    function setSrtParams(
        uint256 _initialPercent,
        uint256 _maturePercent,
        uint256 _maturityBlocks
    ) external onlyOwner {
        require(_initialPercent >= _maturePercent, "initial < mature");
        initialSrtPercent = _initialPercent;
        matureSrtPercent = _maturePercent;
        srtMaturityBlocks = _maturityBlocks;
        emit SrtParamsUpdated(_initialPercent, _maturePercent, _maturityBlocks);
    }

    function setUsdcCollateralPercent(uint256 _percent) external onlyOwner {
        require(_percent >= 100, "percent<100");
        usdcCollateralPercent = _percent;
        emit UsdcCollateralPercentUpdated(_percent);
    }

    function registerMerchant(
        address merchant,
        bool instantOnly
    ) external onlyOwner {
        require(merchant != address(0), "merchant=0");
        isMerchant[merchant] = true;
        merchantInstantOnly[merchant] = instantOnly;
        emit MerchantRegistered(merchant, instantOnly);
    }

    function updateMerchant(
        address merchant,
        bool instantOnly
    ) external onlyOwner {
        require(isMerchant[merchant], "not registered");
        merchantInstantOnly[merchant] = instantOnly;
        emit MerchantUpdated(merchant, instantOnly);
    }

    function sendInstantPayment(
        address merchant,
        uint256 amountUSDC,
        bool collateralIsSRT
    ) external nonReentrant {
        require(isMerchant[merchant], "recipient not merchant");
        require(amountUSDC > 0, "amount=0");
        require(amountUSDC <= softCap, "above soft cap");
        require(
            merchantInstantOnly[merchant],
            "merchant does not accept instant payments"
        );

        if (!collateralIsSRT) {
            uint256 requiredUSDC = (amountUSDC * usdcCollateralPercent + 99) /
                100;
            uint256 freeUSDC = vault.usdcFreeOf(msg.sender);
            require(freeUSDC >= requiredUSDC, "insufficient USDC collateral");

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

            // ⭐ FIX: Updated maturity check to use block.number
            uint256 stakeBlock = vault.srtStakeBlockNumber(msg.sender);
            uint256 percent = initialSrtPercent;
            if (
                stakeBlock > 0 && block.number >= stakeBlock + srtMaturityBlocks
            ) {
                percent = matureSrtPercent;
            }

            uint256 numerator = amountUSDC * percent * 1e20;
            uint256 denominator = 100 * srtPrice;
            uint256 requiredSRT = (numerator + denominator - 1) / denominator;
            uint256 freeSRT = vault.srtFreeOf(msg.sender);
            require(freeSRT >= requiredSRT, "insufficient SRT collateral");

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

    function merchantIsInstantOnly(
        address merchant
    ) external view returns (bool) {
        return merchantInstantOnly[merchant];
    }

    function estimateRequiredSRT(
        uint256 amountUSDC,
        bool useMaturePercent
    ) external view returns (uint256) {
        require(srtPrice > 0, "srtPrice=0");
        uint256 percent = useMaturePercent
            ? matureSrtPercent
            : initialSrtPercent;
        uint256 numerator = amountUSDC * percent * (10 ** 20);
        uint256 denominator = 100 * srtPrice;
        return (numerator + denominator - 1) / denominator;
    }
}
