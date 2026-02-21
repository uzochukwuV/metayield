// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMasterChefV2 {
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function pendingCake(uint256 _pid, address _user) external view returns (uint256);
    function userInfo(uint256 _pid, address _user) external view returns (uint256 amount, uint256 rewardDebt, uint256 boostMultiplier);
    function lpToken(uint256 _pid) external view returns (address);
    function poolLength() external view returns (uint256);
    function emergencyWithdraw(uint256 _pid) external;
    function CAKE() external view returns (address);
}

/**
 * @title PancakeSwapFarmAdapter
 * @notice Standalone adapter for PancakeSwap MasterChefV2 farming operations
 */
contract PancakeSwapFarmAdapter {
    using SafeERC20 for IERC20;

    address public immutable masterChef;
    address public immutable cakeToken;

    enum ActionType { DEPOSIT, WITHDRAW, HARVEST, EMERGENCY_WITHDRAW }

    struct FarmParams {
        ActionType actionType;
        uint256 poolId;
        uint256 amount;
        uint256 minReward;
        uint256 harvestInterval;
        uint256 lastHarvestTime;
        address recipient;
    }

    struct FarmResult {
        uint256 lpAmount;
        uint256 cakeReward;
    }

    event Deposited(uint256 indexed poolId, uint256 amount, address indexed recipient);
    event Withdrawn(uint256 indexed poolId, uint256 amount, uint256 cakeReward, address indexed recipient);
    event Harvested(uint256 indexed poolId, uint256 cakeReward, address indexed recipient);
    event EmergencyWithdrawn(uint256 indexed poolId, uint256 amount, address indexed recipient);

    constructor(address _masterChef) {
        require(_masterChef != address(0), "Invalid masterChef");
        masterChef = _masterChef;
        cakeToken = IMasterChefV2(_masterChef).CAKE();
    }

    function execute(address vault, bytes calldata params)
        external
        returns (bool success, bytes memory result)
    {
        FarmParams memory p = abi.decode(params, (FarmParams));
        _validateParams(p);

        FarmResult memory res;

        if (p.actionType == ActionType.DEPOSIT) {
            res = _deposit(vault, p);
        } else if (p.actionType == ActionType.WITHDRAW) {
            res = _withdraw(vault, p);
        } else if (p.actionType == ActionType.HARVEST) {
            res = _harvest(p);
        } else if (p.actionType == ActionType.EMERGENCY_WITHDRAW) {
            res = _emergencyWithdraw(vault, p);
        } else {
            revert("Invalid action type");
        }

        return (true, abi.encode(res));
    }

    function _validateParams(FarmParams memory p) internal view {
        require(p.recipient != address(0), "Invalid recipient");
        uint256 poolLength = IMasterChefV2(masterChef).poolLength();
        require(p.poolId < poolLength, "Invalid pool ID");
    }

    function _deposit(address /* vault */, FarmParams memory p)
        internal
        returns (FarmResult memory result)
    {
        require(p.amount > 0, "Amount must be > 0");

        address lpToken = IMasterChefV2(masterChef).lpToken(p.poolId);
        IERC20(lpToken).forceApprove(masterChef, p.amount);

        uint256 cakeBefore = IERC20(cakeToken).balanceOf(address(this));
        IMasterChefV2(masterChef).deposit(p.poolId, p.amount);
        uint256 cakeAfter = IERC20(cakeToken).balanceOf(address(this));
        result.cakeReward = cakeAfter - cakeBefore;

        if (result.cakeReward > 0) {
            IERC20(cakeToken).safeTransfer(p.recipient, result.cakeReward);
        }

        result.lpAmount = p.amount;
        emit Deposited(p.poolId, p.amount, p.recipient);
    }

    function _withdraw(address /* vault */, FarmParams memory p)
        internal
        returns (FarmResult memory result)
    {
        address lpToken = IMasterChefV2(masterChef).lpToken(p.poolId);

        uint256 cakeBefore = IERC20(cakeToken).balanceOf(address(this));
        uint256 lpBefore = IERC20(lpToken).balanceOf(address(this));

        IMasterChefV2(masterChef).withdraw(p.poolId, p.amount);

        uint256 cakeAfter = IERC20(cakeToken).balanceOf(address(this));
        uint256 lpAfter = IERC20(lpToken).balanceOf(address(this));

        result.cakeReward = cakeAfter - cakeBefore;
        result.lpAmount = lpAfter - lpBefore;

        if (result.cakeReward > 0) {
            IERC20(cakeToken).safeTransfer(p.recipient, result.cakeReward);
        }

        if (result.lpAmount > 0) {
            IERC20(lpToken).safeTransfer(p.recipient, result.lpAmount);
        }

        emit Withdrawn(p.poolId, result.lpAmount, result.cakeReward, p.recipient);
    }

    function _harvest(FarmParams memory p)
        internal
        returns (FarmResult memory result)
    {
        if (p.harvestInterval > 0 && p.lastHarvestTime > 0) {
            require(
                block.timestamp >= p.lastHarvestTime + p.harvestInterval,
                "Harvest interval not reached"
            );
        }

        uint256 pending = IMasterChefV2(masterChef).pendingCake(p.poolId, p.recipient);
        require(pending >= p.minReward, "Pending rewards below minimum");

        uint256 cakeBefore = IERC20(cakeToken).balanceOf(address(this));
        IMasterChefV2(masterChef).withdraw(p.poolId, 0);
        uint256 cakeAfter = IERC20(cakeToken).balanceOf(address(this));
        result.cakeReward = cakeAfter - cakeBefore;

        if (result.cakeReward > 0) {
            IERC20(cakeToken).safeTransfer(p.recipient, result.cakeReward);
        }

        emit Harvested(p.poolId, result.cakeReward, p.recipient);
    }

    function _emergencyWithdraw(address /* vault */, FarmParams memory p)
        internal
        returns (FarmResult memory result)
    {
        address lpToken = IMasterChefV2(masterChef).lpToken(p.poolId);
        uint256 lpBefore = IERC20(lpToken).balanceOf(address(this));

        IMasterChefV2(masterChef).emergencyWithdraw(p.poolId);

        uint256 lpAfter = IERC20(lpToken).balanceOf(address(this));
        result.lpAmount = lpAfter - lpBefore;

        if (result.lpAmount > 0) {
            IERC20(lpToken).safeTransfer(p.recipient, result.lpAmount);
        }

        emit EmergencyWithdrawn(p.poolId, result.lpAmount, p.recipient);
    }

    function getPendingRewards(uint256 poolId, address user) external view returns (uint256) {
        return IMasterChefV2(masterChef).pendingCake(poolId, user);
    }

    function getStakedAmount(uint256 poolId, address user) external view returns (uint256 stakedAmount) {
        (stakedAmount,,) = IMasterChefV2(masterChef).userInfo(poolId, user);
    }

    function getPoolLPToken(uint256 poolId) external view returns (address) {
        return IMasterChefV2(masterChef).lpToken(poolId);
    }
}
