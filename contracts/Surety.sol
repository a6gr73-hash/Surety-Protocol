// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Surety is ERC20, Ownable {
    // The total supply of SRT is fixed at 1 billion tokens.
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 * 10**18;

    constructor() ERC20("Surety", "SRT") {
        // Mint the entire fixed supply to the deployer on creation.
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}