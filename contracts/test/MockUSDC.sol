// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// A mock ERC20 token that can be configured to fail a transferFrom call
contract MockUSDC is ERC20 {
    bool private _shouldFail;

    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setShouldFail(bool shouldFail) external {
        _shouldFail = shouldFail;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (_shouldFail) {
            // Reset the flag and return false without reverting
            _shouldFail = false;
            return false;
        }
        return super.transferFrom(from, to, amount);
    }
}