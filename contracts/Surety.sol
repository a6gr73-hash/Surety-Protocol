// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./MockOracle.sol";

contract Surety is ERC20, Ownable {

    address public oracle;

    mapping(address => uint256) public stakedBalances;

    uint256 public constant COLLATERALIZATION_RATIO = 110;

    constructor(address _oracleAddress) ERC20("Surety", "SRT") Ownable(msg.sender) {
        require(_oracleAddress != address(0), "Oracle address cannot be zero");
        oracle = _oracleAddress;
        
        _mint(msg.sender, 1_000_000_000 * 10**18);
    }

    /**
     * @dev A secure way to calculate value that avoids rounding errors by multiplying before dividing.
     */
    function _mulDiv(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return (x * y) / z;
    }

    /**
     * @dev Allows a user to stake their SRT tokens to enable instant payments.
     * @param stakeAmount The amount of tokens to stake.
     */
    function stake(uint256 stakeAmount) public {
        require(stakeAmount > 0, "Stake amount must be greater than zero");
        
        // Cast the oracle address to a MockOracle contract type
        uint256 currentPrice = MockOracle(oracle).srtPrice();
        require(currentPrice > 0, "Oracle price must be greater than zero");

        // Calculate the value of the staked tokens using a secure method
        uint256 stakeValue = _mulDiv(stakeAmount, currentPrice, 1e8);
        uint256 currentStakedValue = _mulDiv(stakedBalances[msg.sender], currentPrice, 1e8);
        uint256 newStakedValue = currentStakedValue + stakeValue;

        // Note: The COLLATERALIZATION_RATIO will be used when we implement the payment logic.

        // Transfer tokens from the user to this contract
        _transfer(msg.sender, address(this), stakeAmount);
        
        // Update the user's staked balance
        stakedBalances[msg.sender] += stakeAmount;
    }

    /**
     * @dev Allows a user to unstake their SRT tokens.
     * @param unstakeAmount The amount of tokens to unstake.
     */
    function unstake(uint256 unstakeAmount) public {
        require(unstakeAmount > 0, "Unstake amount must be greater than zero");
        require(stakedBalances[msg.sender] >= unstakeAmount, "Insufficient staked balance");
        
        // Update the user's staked balance
        stakedBalances[msg.sender] -= unstakeAmount;

        // Transfer tokens back to the user
        _transfer(address(this), msg.sender, unstakeAmount);
    }
}