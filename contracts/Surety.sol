// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title Surety
 * @dev Base contract for managing collateralized surety in multi-token staking scenarios.
 *      This contract is designed to be inherited by specific implementations (e.g., CollateralVault, InstantSettlement).
 */
abstract contract Surety {
    struct StakeInfo {
        uint256 amount;       // Amount of tokens staked
        uint256 timestamp;    // Time of staking (used for rewards & collateral decay)
    }

    // Mapping: token address => staker => StakeInfo
    mapping(address => mapping(address => StakeInfo)) internal stakes;

    // Mapping: token address => total staked
    mapping(address => uint256) internal totalStaked;

    event Staked(address indexed token, address indexed staker, uint256 amount);
    event Unstaked(address indexed token, address indexed staker, uint256 amount);
    event Slashed(address indexed token, address indexed staker, uint256 amount, string reason);

    /**
     * @dev Stake a specific ERC20 token.
     * @param token Address of the ERC20 token being staked.
     * @param amount Amount to stake.
     */
    function _stake(address token, uint256 amount) internal virtual {
        require(amount > 0, "Amount must be > 0");
        StakeInfo storage info = stakes[token][msg.sender];
        info.amount += amount;
        info.timestamp = block.timestamp;
        totalStaked[token] += amount;

        emit Staked(token, msg.sender, amount);
    }

    /**
     * @dev Unstake a specific ERC20 token.
     * @param token Address of the ERC20 token being unstaked.
     * @param amount Amount to unstake.
     */
    function _unstake(address token, uint256 amount) internal virtual {
        StakeInfo storage info = stakes[token][msg.sender];
        require(info.amount >= amount, "Not enough staked");
        info.amount -= amount;
        totalStaked[token] -= amount;

        emit Unstaked(token, msg.sender, amount);
    }

    /**
     * @dev Slash a staker's collateral for violating rules.
     * @param token Address of the ERC20 token.
     * @param staker Address of the staker.
     * @param amount Amount to slash.
     * @param reason Reason for slashing.
     */
    function _slash(address token, address staker, uint256 amount, string memory reason) internal virtual {
        StakeInfo storage info = stakes[token][staker];
        require(info.amount >= amount, "Insufficient staked amount to slash");

        info.amount -= amount;
        totalStaked[token] -= amount;

        emit Slashed(token, staker, amount, reason);
    }

    /**
     * @dev Get a staker's stake info for a given token.
     */
    function getStakeInfo(address token, address staker) public view returns (StakeInfo memory) {
        return stakes[token][staker];
    }

    /**
     * @dev Get total staked amount for a token.
     */
    function getTotalStaked(address token) public view returns (uint256) {
        return totalStaked[token];
    }
}