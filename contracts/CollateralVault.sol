// contracts/CollateralVault.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICollateralVault.sol";

/**
 * @title CollateralVault
 * @author FSP Architect
 * @notice A secure vault for users to deposit and stake SRT and USDC collateral.
 * @dev This contract holds all user funds for the Finite Settlement Protocol.
 * It allows an authorized 'settlementContract' (e.g., FiniteSettlement or WatcherRegistry)
 * to lock, release, and slash collateral based on protocol rules. Direct deposits
 * and withdrawals of free stake are initiated by users themselves.
 */
contract CollateralVault is ICollateralVault, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // --- State Variables ---

    IERC20 public immutable srt;
    IERC20 public immutable usdc;

    /// @notice The single, authorized address that can manage collateral locks.
    address public settlementContract;

    /// @notice Mapping from user address to their free (unlocked) SRT balance.
    mapping(address => uint256) public srtStake;
    /// @notice Mapping from user address to their locked SRT balance.
    mapping(address => uint256) public srtLocked;
    /// @notice Mapping from user address to their free (unlocked) USDC balance.
    mapping(address => uint256) public usdcStake;
    /// @notice Mapping from user address to their locked USDC balance.
    mapping(address => uint256) public usdcLocked;

    /// @notice Tracks the block number of a user's first SRT deposit.
    mapping(address => uint256) public srtStakeBlockNumber;

    // --- Events ---

    event SettlementContractSet(address indexed contractAddress);
    event DepositedSRT(address indexed user, uint256 amount);
    event WithdrawnSRT(address indexed user, uint256 amount);
    event LockedSRT(address indexed user, uint256 amount);
    event ReleasedSRT(address indexed user, uint256 amount);
    event SlashedSRT(
        address indexed user,
        address indexed recipient,
        uint256 amount
    );
    event DepositedUSDC(address indexed user, uint256 amount);
    event WithdrawnUSDC(address indexed user, uint256 amount);
    event LockedUSDC(address indexed user, uint256 amount);
    event ReleasedUSDC(address indexed user, uint256 amount);
    event SlashedUSDC(
        address indexed user,
        address indexed recipient,
        uint256 amount
    );

    // --- Modifiers ---

    /**
     * @dev Throws if the caller is not the authorized settlement contract.
     */
    modifier onlySettlement() {
        require(msg.sender == settlementContract, "not settlement");
        _;
    }

    // --- Constructor ---

    constructor(address _srt, address _usdc) {
        require(_srt != address(0), "SRT=0");
        require(_usdc != address(0), "USDC=0");
        srt = IERC20(_srt);
        usdc = IERC20(_usdc);
    }

    // --- Admin Functions ---

    /**
     * @notice Sets the authorized settlement contract address.
     * @dev Can only be called by the contract owner.
     * @param _settlementContract The address of the settlement contract.
     */
    function setSettlementContract(
        address _settlementContract
    ) external onlyOwner {
        require(_settlementContract != address(0), "settlement=0");
        settlementContract = _settlementContract;
        emit SettlementContractSet(_settlementContract);
    }

    // --- User Deposit/Withdraw Functions ---

    /**
     * @notice Deposits SRT into the vault, adding to the user's free stake.
     * @param amount The amount of SRT to deposit.
     */
    function depositSRT(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        if (srtStake[msg.sender] == 0) {
            srtStakeBlockNumber[msg.sender] = block.number;
        }
        srtStake[msg.sender] += amount;
        srt.safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedSRT(msg.sender, amount);
    }

    /**
     * @notice Withdraws free SRT from the vault.
     * @dev Will fail if the user tries to withdraw more than their free `srtStake`.
     * @param amount The amount of SRT to withdraw.
     */
    function withdrawSRT(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(srtStake[msg.sender] >= amount, "insufficient SRT");
        srtStake[msg.sender] -= amount;
        srt.safeTransfer(msg.sender, amount);
        emit WithdrawnSRT(msg.sender, amount);
    }

    /**
     * @notice Deposits USDC into the vault, adding to the user's free stake.
     * @param amount The amount of USDC to deposit.
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        usdcStake[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedUSDC(msg.sender, amount);
    }

    /**
     * @notice Withdraws free USDC from the vault.
     * @dev Will fail if the user tries to withdraw more than their free `usdcStake`.
     * @param amount The amount of USDC to withdraw.
     */
    function withdrawUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(usdcStake[msg.sender] >= amount, "insufficient USDC");
        usdcStake[msg.sender] -= amount;
        usdc.safeTransfer(msg.sender, amount);
        emit WithdrawnUSDC(msg.sender, amount);
    }

    // --- Settlement Contract Functions ---

    /**
     * @notice Moves SRT from a user's free stake to their locked stake.
     * @dev Can only be called by the authorized settlement contract.
     */
    function lockSRT(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(srtStake[user] >= amount, "insufficient free");
        srtStake[user] -= amount;
        srtLocked[user] += amount;
        emit LockedSRT(user, amount);
    }

    /**
     * @notice Moves SRT from a user's locked stake back to their free stake.
     * @dev Can only be called by the authorized settlement contract.
     */
    function releaseSRT(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(srtLocked[user] >= amount, "insufficient locked");
        srtLocked[user] -= amount;
        srtStake[user] += amount;
        emit ReleasedSRT(user, amount);
    }

    /**
     * @notice Removes SRT from a user's locked stake and sends it to a recipient.
     * @dev Can only be called by the authorized settlement contract.
     */
    function slashSRT(
        address user,
        uint256 amount,
        address recipient
    ) external override nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(srtLocked[user] >= amount, "insufficient locked");
        srtLocked[user] -= amount;
        srt.safeTransfer(recipient, amount);
        emit SlashedSRT(user, recipient, amount);
    }

    /**
     * @notice Moves USDC from a user's free stake to their locked stake.
     * @dev Can only be called by the authorized settlement contract.
     */
    function lockUSDC(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(usdcStake[user] >= amount, "insufficient free");
        usdcStake[user] -= amount;
        usdcLocked[user] += amount;
        emit LockedUSDC(user, amount);
    }

    /**
     * @notice Moves USDC from a user's locked stake back to their free stake.
     * @dev Can only be called by the authorized settlement contract.
     */
    function releaseUSDC(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(usdcLocked[user] >= amount, "insufficient locked");
        usdcLocked[user] -= amount;
        usdcStake[user] += amount;
        emit ReleasedUSDC(user, amount);
    }

    /**
     * @notice Removes USDC from a user's locked stake and sends it to a recipient.
     * @dev Can only be called by the authorized settlement contract.
     */
    function slashUSDC(
        address user,
        uint256 amount,
        address recipient
    ) external override nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(usdcLocked[user] >= amount, "insufficient locked");
        usdcLocked[user] -= amount;
        usdc.safeTransfer(recipient, amount);
        emit SlashedUSDC(user, recipient, amount);
    }

    // --- View Functions ---

    /**
     * @notice Returns a user's free SRT balance.
     */
    function srtFreeOf(address user) external view returns (uint256) {
        return srtStake[user];
    }

    /**
     * @notice Returns a user's locked SRT balance.
     */
    function srtLockedOf(address user) external view returns (uint256) {
        return srtLocked[user];
    }

    /**
     * @notice Returns a user's total (free + locked) SRT balance.
     */
    function srtTotalOf(address user) external view returns (uint256) {
        return srtStake[user] + srtLocked[user];
    }

    /**
     * @notice Returns a user's free USDC balance.
     */
    function usdcFreeOf(address user) external view returns (uint256) {
        return usdcStake[user];
    }

    /**
     * @notice Returns a user's locked USDC balance.
     */
    function usdcLockedOf(address user) external view returns (uint256) {
        return usdcLocked[user];
    }

    /**
     * @notice Returns a user's total (free + locked) USDC balance.
     */
    function usdcTotalOf(address user) external view returns (uint256) {
        return usdcStake[user] + usdcLocked[user];
    }
}
