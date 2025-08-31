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
 * @notice A secure vault for users to deposit and manage SRT and USDC collateral.
 * @dev This contract holds all user funds for the Finite Settlement Protocol. It allows
 * a whitelist of authorized 'settlement contracts' (e.g., FiniteSettlement, WatcherRegistry)
 * to lock, release, and slash collateral based on protocol rules. Direct deposits and
 * withdrawals of free (unlocked) stake are initiated by users themselves.
 */
contract CollateralVault is ICollateralVault, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // --- State Variables ---

    /// @notice The immutable address of the Surety (SRT) token contract.
    IERC20 public immutable srt;
    /// @notice The immutable address of the USDC token contract.
    IERC20 public immutable usdc;

    /// @notice A mapping that defines the whitelist of authorized settlement contracts.
    mapping(address => bool) public isSettlementContract;

    /// @notice Mapping from a user's address to their free (unlocked) SRT balance.
    mapping(address => uint256) public srtStake;
    /// @notice Mapping from a user's address to their locked SRT balance.
    mapping(address => uint256) public srtLocked;
    /// @notice Mapping from a user's address to their free (unlocked) USDC balance.
    mapping(address => uint256) public usdcStake;
    /// @notice Mapping from a user's address to their locked USDC balance.
    mapping(address => uint256) public usdcLocked;

    // --- Events ---

    event SettlementContractAdded(address indexed contractAddress);
    event SettlementContractRemoved(address indexed contractAddress);
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
     * @dev Throws if the caller is not an authorized settlement contract.
     */
    modifier onlySettlement() {
        require(
            isSettlementContract[msg.sender],
            "CollateralVault: Caller is not an authorized settlement contract"
        );
        _;
    }

    // --- Constructor ---

    constructor(address _srt, address _usdc) {
        require(
            _srt != address(0),
            "CollateralVault: SRT address cannot be zero"
        );
        require(
            _usdc != address(0),
            "CollateralVault: USDC address cannot be zero"
        );
        srt = IERC20(_srt);
        usdc = IERC20(_usdc);
    }

    // --- Admin Functions ---

    /**
     * @notice Adds a contract address to the settlement authorization whitelist.
     * @dev Can only be called by the contract owner.
     * @param _contractAddress The address of the settlement contract to authorize.
     */
    function addSettlementContract(
        address _contractAddress
    ) external onlyOwner {
        require(
            _contractAddress != address(0),
            "CollateralVault: Contract address cannot be zero"
        );
        require(
            !isSettlementContract[_contractAddress],
            "CollateralVault: Contract already authorized"
        );
        isSettlementContract[_contractAddress] = true;
        emit SettlementContractAdded(_contractAddress);
    }

    /**
     * @notice Removes a contract address from the settlement authorization whitelist.
     * @dev Can only be called by the contract owner.
     * @param _contractAddress The address of the settlement contract to de-authorize.
     */
    function removeSettlementContract(
        address _contractAddress
    ) external onlyOwner {
        require(
            isSettlementContract[_contractAddress],
            "CollateralVault: Contract not authorized"
        );
        isSettlementContract[_contractAddress] = false;
        emit SettlementContractRemoved(_contractAddress);
    }

    // --- User Deposit/Withdraw Functions ---

    /**
     * @notice Deposits SRT into the vault, adding to the user's free stake.
     * @param amount The amount of SRT to deposit.
     */
    function depositSRT(uint256 amount) external nonReentrant {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        srtStake[msg.sender] += amount;
        srt.safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedSRT(msg.sender, amount);
    }

    /**
     * @notice Withdraws free SRT from the vault.
     * @dev Fails if the user tries to withdraw more than their free `srtStake`.
     * @param amount The amount of SRT to withdraw.
     */
    function withdrawSRT(uint256 amount) external nonReentrant {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        uint256 currentStake = srtStake[msg.sender];
        require(
            currentStake >= amount,
            "CollateralVault: Insufficient free SRT stake"
        );
        srtStake[msg.sender] = currentStake - amount;
        srt.safeTransfer(msg.sender, amount);
        emit WithdrawnSRT(msg.sender, amount);
    }

    /**
     * @notice Deposits USDC into the vault, adding to the user's free stake.
     * @param amount The amount of USDC to deposit.
     */
    function depositUSDC(uint256 amount) external nonReentrant {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        usdcStake[msg.sender] += amount;
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedUSDC(msg.sender, amount);
    }

    /**
     * @notice Withdraws free USDC from the vault.
     * @dev Fails if the user tries to withdraw more than their free `usdcStake`.
     * @param amount The amount of USDC to withdraw.
     */
    function withdrawUSDC(uint256 amount) external nonReentrant {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        uint256 currentStake = usdcStake[msg.sender];
        require(
            currentStake >= amount,
            "CollateralVault: Insufficient free USDC stake"
        );
        usdcStake[msg.sender] = currentStake - amount;
        usdc.safeTransfer(msg.sender, amount);
        emit WithdrawnUSDC(msg.sender, amount);
    }

    // --- Settlement Contract Functions ---

    function lockSRT(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        uint256 userStake = srtStake[user];
        require(
            userStake >= amount,
            "CollateralVault: Insufficient free SRT to lock"
        );
        srtStake[user] = userStake - amount;
        srtLocked[user] += amount;
        emit LockedSRT(user, amount);
    }

    function releaseSRT(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        uint256 userLocked = srtLocked[user];
        require(
            userLocked >= amount,
            "CollateralVault: Insufficient locked SRT to release"
        );
        srtLocked[user] = userLocked - amount;
        srtStake[user] += amount;
        emit ReleasedSRT(user, amount);
    }

    function slashSRT(
        address user,
        uint256 amount,
        address recipient
    ) external override nonReentrant onlySettlement {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        require(
            recipient != address(0),
            "CollateralVault: Recipient address cannot be zero"
        );
        uint256 userLocked = srtLocked[user];
        require(
            userLocked >= amount,
            "CollateralVault: Insufficient locked SRT to slash"
        );
        srtLocked[user] = userLocked - amount;
        srt.safeTransfer(recipient, amount);
        emit SlashedSRT(user, recipient, amount);
    }

    function lockUSDC(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        uint256 userStake = usdcStake[user];
        require(
            userStake >= amount,
            "CollateralVault: Insufficient free USDC to lock"
        );
        usdcStake[user] = userStake - amount;
        usdcLocked[user] += amount;
        emit LockedUSDC(user, amount);
    }

    function releaseUSDC(
        address user,
        uint256 amount
    ) external override nonReentrant onlySettlement {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        uint256 userLocked = usdcLocked[user];
        require(
            userLocked >= amount,
            "CollateralVault: Insufficient locked USDC to release"
        );
        usdcLocked[user] = userLocked - amount;
        usdcStake[user] += amount;
        emit ReleasedUSDC(user, amount);
    }

    function slashUSDC(
        address user,
        uint256 amount,
        address recipient
    ) external override nonReentrant onlySettlement {
        require(
            amount > 0,
            "CollateralVault: Amount must be greater than zero"
        );
        require(
            recipient != address(0),
            "CollateralVault: Recipient address cannot be zero"
        );
        uint256 userLocked = usdcLocked[user];
        require(
            userLocked >= amount,
            "CollateralVault: Insufficient locked USDC to slash"
        );
        usdcLocked[user] = userLocked - amount;
        usdc.safeTransfer(recipient, amount);
        emit SlashedUSDC(user, recipient, amount);
    }

    // --- View Functions ---

    function srtFreeOf(address user) external view returns (uint256) {
        return srtStake[user];
    }

    function srtLockedOf(address user) external view returns (uint256) {
        return srtLocked[user];
    }

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
