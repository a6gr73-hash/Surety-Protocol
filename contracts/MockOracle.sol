// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockOracle
 * @dev A simple contract to simulate a price oracle for testing purposes.
 * It holds a mock price feed that can only be updated by the owner.
 */
contract MockOracle is Ownable {
    uint256 public srtPrice; // The price of 1 SRT token in USD, with 8 decimals

    event PriceUpdated(uint256 newPrice);

    constructor(uint256 initialPrice) Ownable(msg.sender) {
        srtPrice = initialPrice;
    }

    /**
     * @dev Updates the mock price feed. Can only be called by the owner.
     * @param newPrice The new price of the SRT token.
     */
    function updatePrice(uint256 newPrice) public onlyOwner {
        require(newPrice > 0, "Price must be greater than zero");
        srtPrice = newPrice;
        emit PriceUpdated(newPrice);
    }
}