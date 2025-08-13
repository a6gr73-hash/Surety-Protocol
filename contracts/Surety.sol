// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";


contract Surety is ERC20, Ownable {

    constructor(uint256 initialSupply) ERC20("Surety", "SRT") Ownable(msg.sender) {
        _mint(msg.sender, initialSupply);
    }

    /**
     * @notice Allows the owner to mint additional tokens.
     * @param to The address to mint tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Allows the owner to burn tokens from any address.
     * @param from The address to burn tokens from.
     * @param amount The amount of tokens to burn.
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}