// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// This interface defines the functions needed from the CollateralVault.
// It is a best practice to define interfaces in the contract that uses them.
interface ICollateralVault {
    function srtLocked(address user) external view returns (uint256);

    function lockSRT(address user, uint256 amount) external;

    function releaseSRT(address user, uint256 amount) external;

    function slashSRT(address user, uint256 amount, address recipient) external;
}

contract WatcherRegistry is Ownable, ReentrancyGuard {
    ICollateralVault public immutable collateralVault;

    // --- State Variables ---
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

    constructor(address _collateralVault, uint256 _minStake) Ownable() {
        require(
            _collateralVault != address(0),
            "WatcherRegistry: Vault address cannot be zero"
        );
        require(
            _minStake > 0,
            "WatcherRegistry: Minimum stake must be greater than zero"
        );
        collateralVault = ICollateralVault(_collateralVault);
        minWatcherStake = _minStake;
    }

    /**
     * @notice Allows an address to register as a watcher by locking a minimum amount of SRT.
     * @param amount The amount of SRT to lock, which must be at least the minimum required stake.
     * @dev The user must have already deposited and approved the necessary SRT in the CollateralVault.
     */
    function registerWatcher(uint256 amount) external nonReentrant {
        require(!isWatcher[msg.sender], "WatcherRegistry: Already registered");
        require(
            amount >= minWatcherStake,
            "WatcherRegistry: Insufficient stake amount"
        );

        collateralVault.lockSRT(msg.sender, amount);

        isWatcher[msg.sender] = true;
        emit WatcherRegistered(msg.sender, amount);
    }

    /**
     * @notice Initiates the deregistration process for a watcher, starting a time-lock.
     * @dev The watcher's funds remain locked for the duration of UNSTAKE_BLOCKS.
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
     * @notice Allows a deregistered watcher to claim their locked stake after the unstake period has passed.
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

        uint256 lockedAmount = collateralVault.srtLocked(msg.sender);
        require(lockedAmount > 0, "WatcherRegistry: No funds to claim");

        // Update state BEFORE the external call to prevent reentrancy
        isWatcher[msg.sender] = false;
        delete unstakeRequestBlock[msg.sender];

        // External call to the vault
        collateralVault.releaseSRT(msg.sender, lockedAmount);

        emit WatcherFundsClaimed(msg.sender, lockedAmount);
    }

    /**
     * @notice Allows the owner (or a future DAO) to slash a watcher's stake for misbehavior.
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
     * @notice Allows the owner to update the minimum required stake for new watchers.
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
}