// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CollateralVault is ReentrancyGuard, Ownable {
    IERC20 public immutable SRT;
    IERC20 public immutable USDC;

    address public settlementContract;

    mapping(address => uint256) public srtStake;
    mapping(address => uint256) public srtLocked;
    mapping(address => uint256) public usdcStake;
    mapping(address => uint256) public usdcLocked;
    mapping(address => uint256) public srtStakeTimestamp;

    // --- Events ---
    event SettlementContractSet(address indexed contractAddress);
    event DepositedSRT(address indexed user, uint256 amount);
    event WithdrawnSRT(address indexed user, uint256 amount);
    event LockedSRT(address indexed user, uint256 amount);
    event ReleasedSRT(address indexed user, uint256 amount);
    event SlashedSRT(
        address indexed user,
        address indexed recipient,
        uint256 amount
    );
    event DepositedUSDC(address indexed user, uint256 amount);
    event WithdrawnUSDC(address indexed user, uint256 amount);
    event LockedUSDC(address indexed user, uint256 amount);
    event ReleasedUSDC(address indexed user, uint256 amount);
    event SlashedUSDC(
        address indexed user,
        address indexed recipient,
        uint256 amount
    );

    modifier onlySettlement() {
        require(msg.sender == settlementContract, "not settlement");
        _;
    }

    // --- Constructor ---
    constructor(address _srt, address _usdc) {
        require(_srt != address(0), "SRT=0");
        require(_usdc != address(0), "USDC=0");
        SRT = IERC20(_srt);
        USDC = IERC20(_usdc);
    }

    // --- Admin ---
    function setSettlementContract(address _settlement) external onlyOwner {
        require(_settlement != address(0), "settlement=0");
        settlementContract = _settlement;
        emit SettlementContractSet(_settlement);
    }

    // --- SRT functions ---
    function depositSRT(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        if (srtStake[msg.sender] == 0 && srtLocked[msg.sender] == 0) {
            srtStakeTimestamp[msg.sender] = block.timestamp;
        }
        srtStake[msg.sender] += amount;
        require(
            SRT.transferFrom(msg.sender, address(this), amount),
            "transferFrom failed"
        );
        emit DepositedSRT(msg.sender, amount);
    }

    function withdrawSRT(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(srtStake[msg.sender] >= amount, "insufficient SRT");
        srtStake[msg.sender] -= amount;
        require(SRT.transfer(msg.sender, amount), "transfer failed");
        emit WithdrawnSRT(msg.sender, amount);
    }

    function lockSRT(
        address user,
        uint256 amount
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(srtStake[user] >= amount, "insufficient free");
        srtStake[user] -= amount;
        srtLocked[user] += amount;
        emit LockedSRT(user, amount);
    }

    function releaseSRT(
        address user,
        uint256 amount
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(srtLocked[user] >= amount, "insufficient locked");
        srtLocked[user] -= amount;
        srtStake[user] += amount;
        emit ReleasedSRT(user, amount);
    }

    function slashSRT(
        address user,
        uint256 amount,
        address recipient
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(srtLocked[user] >= amount, "insufficient locked");
        srtLocked[user] -= amount;
        require(SRT.transfer(recipient, amount), "slash transfer failed");
        emit SlashedSRT(user, recipient, amount);
    }

    // --- USDC functions ---
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        usdcStake[msg.sender] += amount;
        require(
            USDC.transferFrom(msg.sender, address(this), amount),
            "transferFrom failed"
        );
        emit DepositedUSDC(msg.sender, amount);
    }

    function withdrawUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "amount=0");
        require(usdcStake[msg.sender] >= amount, "insufficient USDC");
        usdcStake[msg.sender] -= amount;
        require(USDC.transfer(msg.sender, amount), "transfer failed");
        emit WithdrawnUSDC(msg.sender, amount);
    }

    function lockUSDC(
        address user,
        uint256 amount
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(usdcStake[user] >= amount, "insufficient free");
        usdcStake[user] -= amount;
        usdcLocked[user] += amount;
        emit LockedUSDC(user, amount);
    }

    function releaseUSDC(
        address user,
        uint256 amount
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(usdcLocked[user] >= amount, "insufficient locked");
        usdcLocked[user] -= amount;
        usdcStake[user] += amount;
        emit ReleasedUSDC(user, amount);
    }

    function slashUSDC(
        address user,
        uint256 amount,
        address recipient
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(recipient != address(0), "recipient=0");
        require(usdcLocked[user] >= amount, "insufficient locked");
        usdcLocked[user] -= amount;
        require(USDC.transfer(recipient, amount), "slash transfer failed");
        emit SlashedUSDC(user, recipient, amount);
    }

    // --- CORRECTED REIMBURSEMENT FUNCTIONS ---
    function reimburseAndStakeSRT(
        address user,
        uint256 amount
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(
            SRT.transferFrom(msg.sender, address(this), amount),
            "Reimbursement transfer failed"
        );
        srtStake[user] += amount;
        emit DepositedSRT(user, amount);
    }

    function reimburseAndStakeUSDC(
        address user,
        uint256 amount
    ) external nonReentrant onlySettlement {
        require(amount > 0, "amount=0");
        require(
            USDC.transferFrom(msg.sender, address(this), amount),
            "Reimbursement transfer failed"
        );
        usdcStake[user] += amount;
        emit DepositedUSDC(user, amount);
    }

    // --- Views ---
    function srtTotalOf(address user) external view returns (uint256) {
        return srtStake[user] + srtLocked[user];
    }

    function usdcTotalOf(address user) external view returns (uint256) {
        return usdcStake[user] + usdcLocked[user];
    }
}
