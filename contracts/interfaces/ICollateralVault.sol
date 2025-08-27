// contracts/interfaces/ICollateralVault.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title ICollateralVault
 * @author FSP Architect
 * @notice The canonical interface for the CollateralVault contract.
 * @dev Defines all functions that authorized settlement contracts can call to
 * manage user collateral (locking, releasing, and slashing). Also includes
 * view functions needed by other contracts.
 */
interface ICollateralVault {
    /**
     * @notice Locks a user's free SRT stake.
     * @param user The address of the user whose stake will be locked.
     * @param amount The amount of SRT to lock.
     */
    function lockSRT(address user, uint256 amount) external;

    /**
     * @notice Releases a user's locked SRT stake back to their free balance.
     * @param user The address of the user whose stake will be released.
     * @param amount The amount of SRT to release.
     */
    function releaseSRT(address user, uint256 amount) external;

    /**
     * @notice Slashes a user's locked SRT stake, transferring it to a recipient.
     * @param user The address of the user whose stake will be slashed.
     * @param amount The amount of SRT to slash.
     * @param recipient The address to receive the slashed funds.
     */
    function slashSRT(address user, uint256 amount, address recipient) external;

    /**
     * @notice Locks a user's free USDC stake.
     * @param user The address of the user whose stake will be locked.
     * @param amount The amount of USDC to lock.
     */
    function lockUSDC(address user, uint256 amount) external;

    /**
     * @notice Releases a user's locked USDC stake back to their free balance.
     * @param user The address of the user whose stake will be released.
     * @param amount The amount of USDC to release.
     */
    function releaseUSDC(address user, uint256 amount) external;

    /**
     * @notice Slashes a user's locked USDC stake, transferring it to a recipient.
     * @param user The address of the user whose stake will be slashed.
     * @param amount The amount of USDC to slash.
     * @param recipient The address to receive the slashed funds.
     */
    function slashUSDC(address user, uint256 amount, address recipient) external;

    /**
     * @notice Returns the amount of SRT a user has locked.
     * @param user The address of the user.
     * @return The amount of locked SRT.
     */
    function srtLocked(address user) external view returns (uint256);
}