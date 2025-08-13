// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


import "./CollateralVault.sol";

contract InstantSettlement is ReentrancyGuard {
    CollateralVault public vault;
    IERC20 public stablecoin;

    uint256 public requiredCollateralPercent = 110;

    event PaymentSent(address indexed sender, address indexed receiver, uint256 amount);
    event PaymentFailed(address indexed sender, address indexed receiver, uint256 amount);
    event SlashedCollateralHeld(address indexed user, uint256 slashedAmount);

    constructor(address _vaultAddress, address _stablecoinAddress) {
        vault = CollateralVault(_vaultAddress);
        stablecoin = IERC20(_stablecoinAddress);
    }

    function sendPayment(address receiver, uint256 amount) external nonReentrant {
        uint256 senderUnlockedStake = vault.stakes(msg.sender);
        uint256 collateralRequired = (amount * requiredCollateralPercent) / 100;
        require(senderUnlockedStake >= collateralRequired, "Insufficient unlocked collateral");

        vault.lock(msg.sender, collateralRequired);

        bool success = stablecoin.transferFrom(msg.sender, receiver, amount);

        if (success) {
            vault.release(msg.sender, collateralRequired);
            emit PaymentSent(msg.sender, receiver, amount);
        } else {
            vault.slash(msg.sender, collateralRequired);
            
            emit PaymentFailed(msg.sender, receiver, amount);
            
            emit SlashedCollateralHeld(msg.sender, collateralRequired);
        }
    }
}