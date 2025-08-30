// contracts/WatcherRegistry.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICollateralVault.sol";

/**
 * @title WatcherRegistry
 * @author FSP Architect
 * @notice Manages the registration, staking, and slashing of network watchers.
 * @dev This contract is responsible for maintaining the list of active watchers
 * and managing their SRT stakes via the CollateralVault. It now also includes
 * a mechanism for the DAO/owner to distribute USDC stipends to watchers.
 */
contract WatcherRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- State Variables ---
    ICollateralVault public immutable collateralVault;
    // NEW: The contract now needs to know about the USDC token to distribute stipends.
    IERC20 public immutable usdc;

    mapping(address => bool) public isWatcher;
    mapping(address => uint256) public unstakeRequestBlock;

    uint256 public constant UNSTAKE_BLOCKS = 216000; // ~30 days
    uint256 public minWatcherStake;

    // --- Events ---
    event WatcherRegistered(address indexed watcher, uint256 stakedAmount);
    event WatcherDeregistered(address indexed watcher, uint256 requestBlock);
    event WatcherFundsClaimed(address indexed watcher, uint256 amount);
    event WatcherSlashed(
        address indexed watcher,
        address indexed recipient,
        uint256 slashedAmount
    );
    event MinWatcherStakeUpdated(uint256 newAmount);
    // NEW: Event for when stipends are distributed.
    event StipendsDistributed(uint256 totalAmount, uint256 watcherCount);

    // MODIFIED: The constructor now accepts the USDC contract address.
    constructor(
        address _collateralVault,
        address _usdcAddress,
        uint256 _minStake
    ) {
        require(
            _collateralVault != address(0),
            "WatcherRegistry: Vault address cannot be zero"
        );
        require(
            _usdcAddress != address(0),
            "WatcherRegistry: USDC address cannot be zero"
        );
        require(
            _minStake > 0,
            "WatcherRegistry: Minimum stake must be greater than zero"
        );

        collateralVault = ICollateralVault(_collateralVault);
        usdc = IERC20(_usdcAddress);
        minWatcherStake = _minStake;
    }

    /**
     * @notice Allows an address to register as a watcher by locking a minimum amount of SRT.
     * @dev The user must have already deposited the necessary SRT in the CollateralVault.
     * @param amount The amount of SRT to lock, must be >= minWatcherStake.
     */
    function registerWatcher(uint256 amount) external nonReentrant {
        require(!isWatcher[msg.sender], "WatcherRegistry: Already registered");
        require(
            amount >= minWatcherStake,
            "WatcherRegistry: Insufficient stake amount"
        );

        isWatcher[msg.sender] = true;
        collateralVault.lockSRT(msg.sender, amount);

        emit WatcherRegistered(msg.sender, amount);
    }

    /**
     * @notice Initiates the deregistration process for a watcher, starting a time-lock.
     */
    function deregisterWatcher() external nonReentrant {
        require(
            isWatcher[msg.sender],
            "WatcherRegistry: Not a registered watcher"
        );
        unstakeRequestBlock[msg.sender] = block.number;
        emit WatcherDeregistered(msg.sender, block.number);
    }

    /**
     * @notice Allows a deregistered watcher to claim their locked stake after the unstake period.
     */
    function claimUnstakedFunds() external nonReentrant {
        require(
            isWatcher[msg.sender],
            "WatcherRegistry: Not a registered watcher"
        );
        require(
            unstakeRequestBlock[msg.sender] > 0,
            "WatcherRegistry: Deregistration not initiated"
        );
        require(
            block.number >= unstakeRequestBlock[msg.sender] + UNSTAKE_BLOCKS,
            "WatcherRegistry: Unstake period not over"
        );

        uint256 lockedAmount = collateralVault.srtLockedOf(msg.sender);
        require(lockedAmount > 0, "WatcherRegistry: No funds to claim");

        isWatcher[msg.sender] = false;
        delete unstakeRequestBlock[msg.sender];

        collateralVault.releaseSRT(msg.sender, lockedAmount);

        emit WatcherFundsClaimed(msg.sender, lockedAmount);
    }

    /**
     * @notice Slashes a watcher's stake for misbehavior.
     * @param watcher The address of the watcher to be slashed.
     * @param amount The amount of SRT to slash from the watcher's locked funds.
     * @param recipient The address to receive the slashed funds.
     */
    function slashWatcher(
        address watcher,
        uint256 amount,
        address recipient
    ) external nonReentrant onlyOwner {
        require(
            isWatcher[watcher],
            "WatcherRegistry: Not a registered watcher"
        );
        require(
            recipient != address(0),
            "WatcherRegistry: Invalid recipient address"
        );
        collateralVault.slashSRT(watcher, amount, recipient);
        emit WatcherSlashed(watcher, recipient, amount);
    }

    /**
     * @notice Updates the minimum required stake for new watchers.
     * @param newMinStake The new minimum stake amount.
     */
    function setMinWatcherStake(uint256 newMinStake) external onlyOwner {
        require(
            newMinStake > 0,
            "WatcherRegistry: Minimum stake must be greater than zero"
        );
        minWatcherStake = newMinStake;
        emit MinWatcherStakeUpdated(newMinStake);
    }

    /**
     * @notice NEW: Distributes USDC stipends to a batch of active watchers.
     * @dev The contract must hold sufficient USDC (sent from the treasury) before this is called.
     * The owner is responsible for providing a valid list of active watchers to avoid reverts.
     * This batching mechanism is used to avoid unbounded loops and stay within block gas limits.
     * @param watchers A list of watcher addresses to receive stipends.
     * @param amountPerWatcher The amount of USDC to send to each watcher.
     */
    function distributeStipends(
        address[] calldata watchers,
        uint256 amountPerWatcher
    ) external nonReentrant onlyOwner {
        uint256 totalAmount = watchers.length * amountPerWatcher;
        require(
            usdc.balanceOf(address(this)) >= totalAmount,
            "WatcherRegistry: Insufficient USDC balance for distribution"
        );

        for (uint i = 0; i < watchers.length; i++) {
            address watcher = watchers[i];
            // Ensure we are only paying active, staked watchers.
            require(
                isWatcher[watcher],
                "WatcherRegistry: Cannot pay stipend to a non-watcher"
            );
            usdc.safeTransfer(watcher, amountPerWatcher);
        }

        emit StipendsDistributed(totalAmount, watchers.length);
    }
}