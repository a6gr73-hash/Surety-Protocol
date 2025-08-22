// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// This interface must be updated with any changes to the CollateralVault contract.
interface ICollateralVault {
    function srtStake(address user) external view returns (uint256);
    function srtLocked(address user) external view returns (uint256);
    function lockSRT(address user, uint256 amount) external;
    function releaseSRT(address user, uint256 amount) external;
    function slashSRT(address user, uint256 amount, address recipient) external;
    function srtStakeBlockNumber(address user) external view returns (uint256);
}

contract WatcherRegistry is Ownable, ReentrancyGuard {

    ICollateralVault public immutable collateralVault;

    // --- State Variables ---
    mapping(address => bool) public isWatcher;
    mapping(address => uint256) public unstakeRequests;
    uint256 public constant UNSTAKE_PERIOD = 30 days;
    uint256 public minWatcherStake;

    // --- Events ---
    event WatcherRegistered(address indexed watcher, uint256 stakedAmount);
    event WatcherDeregistered(address indexed watcher);
    event WatcherSlashed(address indexed watcher, uint256 slashedAmount);
    event MinWatcherStakeUpdated(uint256 oldAmount, uint256 newAmount);

    constructor(address _collateralVault, uint256 _minStake) Ownable() {
        require(_collateralVault != address(0), "Watcher: vault=0");
        require(_minStake > 0, "Watcher: minStake=0");
        collateralVault = ICollateralVault(_collateralVault);
        minWatcherStake = _minStake;
    }

    /**
     * @notice Allows an address to register as a watcher by locking a minimum amount of SRT.
     * @param amount The amount of SRT to stake, which must be at least the minimum.
     * @dev This function relies on the user having already deposited SRT into the CollateralVault.
     */
    function registerWatcher(uint256 amount) external nonReentrant {
        require(amount >= minWatcherStake, "Watcher: not enough collateral");
        require(!isWatcher[msg.sender], "Watcher: already registered");
        
        // Lock the SRT from the user's unlocked stake in the CollateralVault
        collateralVault.lockSRT(msg.sender, amount);
        
        isWatcher[msg.sender] = true;
        emit WatcherRegistered(msg.sender, amount);
    }
    
    /**
     * @notice Initiates the deregistration process for a watcher.
     * @dev The watcher's stake remains locked for the UNSTAKE_PERIOD to allow for potential slashing.
     */
    function deregisterWatcher() external nonReentrant {
        require(isWatcher[msg.sender], "Watcher: not a watcher");
        
        // Record the time of the deregistration request
        unstakeRequests[msg.sender] = block.timestamp;
        emit WatcherDeregistered(msg.sender);
    }

    /**
     * @notice Allows a deregistered watcher to claim their stake after the unstake period.
     * @dev Calls the CollateralVault to release the locked funds.
     */
    function claimUnstakedFunds() external nonReentrant {
        require(isWatcher[msg.sender], "Watcher: not a watcher");
        require(unstakeRequests[msg.sender] > 0, "Watcher: not deregistered");
        require(block.timestamp >= unstakeRequests[msg.sender] + UNSTAKE_PERIOD, "Watcher: unstake period not over");

        // The full locked amount is determined by the CollateralVault
        uint256 lockedAmount = collateralVault.srtLocked(msg.sender);

        // Call the CollateralVault to release the funds
        collateralVault.releaseSRT(msg.sender, lockedAmount);
        
        // Reset state
        isWatcher[msg.sender] = false;
        delete unstakeRequests[msg.sender];
    }
    
    /**
     * @notice Allows a trusted entity (the owner or a future DAO) to slash a watcher's stake.
     * @dev This function is intended to be called after a watcher's misbehavior has been proven.
     * @param watcher The address of the watcher to be slashed.
     * @param amount The amount of SRT to slash.
     * @param recipient The address to receive the slashed funds.
     */
    function slashWatcher(address watcher, uint256 amount, address recipient) external nonReentrant onlyOwner {
        require(isWatcher[watcher], "Watcher: not a watcher");
        
        // Call the CollateralVault to slash the funds
        collateralVault.slashSRT(watcher, amount, recipient);
        emit WatcherSlashed(watcher, amount);
    }

    /**
     * @notice Allows the owner to update the minimum required stake for new watchers.
     * @param newAmount The new minimum stake amount.
     */
    function setMinWatcherStake(uint256 newAmount) external onlyOwner {
        require(newAmount > 0, "Watcher: amount=0");
        uint256 oldAmount = minWatcherStake;
        minWatcherStake = newAmount;
        emit MinWatcherStakeUpdated(oldAmount, newAmount);
    }
}