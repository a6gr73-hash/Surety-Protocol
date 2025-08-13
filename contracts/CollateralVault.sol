// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralVault is ReentrancyGuard, Ownable {
    IERC20 public immutable SRT;
    address public settlementContract;

    mapping(address => uint256) public stakes;
    mapping(address => uint256) public lockedStakes;

    event SettlementContractSet(address indexed contractAddress);
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Locked(address indexed user, uint256 amount);
    event Released(address indexed user, uint256 amount);
    event Slashed(address indexed user, address indexed beneficiary, uint256 amount);

    modifier onlySettlementContract() {
        require(msg.sender == settlementContract, "Caller is not the settlement contract");
        _;
    }

    constructor(IERC20 _token) Ownable(msg.sender) {
        SRT = _token;
    }

    function setSettlementContract(address _settlementContract) external onlyOwner {
        require(_settlementContract != address(0), "Invalid address");
        settlementContract = _settlementContract;
        emit SettlementContractSet(_settlementContract);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit must be > 0");
        stakes[msg.sender] += amount;
        require(SRT.transferFrom(msg.sender, address(this), amount), "SRT transfer failed");
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        require(stakes[msg.sender] >= amount, "Insufficient unlocked stake");
        stakes[msg.sender] -= amount;
        require(SRT.transfer(msg.sender, amount), "SRT transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    function lock(address user, uint256 amount) external nonReentrant onlySettlementContract {
        require(stakes[user] >= amount, "Insufficient unlocked stake to lock");
        stakes[user] -= amount;
        lockedStakes[user] += amount;
        emit Locked(user, amount);
    }

    function release(address user, uint256 amount) external nonReentrant onlySettlementContract {
        require(lockedStakes[user] >= amount, "Insufficient locked stake to release");
        lockedStakes[user] -= amount;
        stakes[user] += amount;
        emit Released(user, amount);
    }

    function slash(address user, uint256 amount) external nonReentrant onlySettlementContract {
        require(lockedStakes[user] >= amount, "Insufficient locked stake to slash");
        lockedStakes[user] -= amount;
        require(SRT.transfer(settlementContract, amount), "Slash transfer failed");
        emit Slashed(user, settlementContract, amount);
    }

    function totalStakeOf(address user) external view returns (uint256) {
        return stakes[user] + lockedStakes[user];
    }
}