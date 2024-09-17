// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// MockOracle interface, replace with your actual MockOracle interface
interface MockOracle {
    function getPrice() external view returns (uint256);
}

contract AdaptiveLiquidityAMM is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    struct Asset {
        IERC20 token;
        uint256 reserve;
        uint256 weight;
        MockOracle priceFeed;  
    }
  
    Asset[] public assets;
    uint256 public constant WEIGHT_PRECISION = 1e18;
    uint256 public constant FEE_PRECISION = 10000;
    uint256 public baseFee = 30; // 0.3%
    uint256 public dynamicFeeRange = 20; // 0.2%
    uint256 public impermanentLossFund;
    uint256 public lastRebalanceTimestamp;
    uint256 public rebalanceInterval = 1 hours;

    mapping(address => uint256) public userLiquidity;
    uint256 public totalLiquidity;

    event LiquidityAdded(address indexed user, uint256[] amounts, uint256 liquidity);
    event LiquidityRemoved(address indexed user, uint256[] amounts, uint256 liquidity);
    event Swap(address indexed user, uint256 inputAssetIndex, uint256 outputAssetIndex, uint256 inputAmount, uint256 outputAmount);
    event FeesUpdated(uint256 newBaseFee, uint256 newDynamicFeeRange);
    event Rebalanced(uint256[] newWeights);

    constructor(
        address xfiToken, 
        address xfiPriceFeed,
        address mpxToken,
        address mpxPriceFeed
    ) Ownable(msg.sender){
        assets.push(Asset({
            token: IERC20(xfiToken),
            reserve: 0,
            weight: WEIGHT_PRECISION / 2, 
            priceFeed: MockOracle(xfiPriceFeed)  
        }));
        assets.push(Asset({
            token: IERC20(mpxToken),
            reserve: 0,
            weight: WEIGHT_PRECISION / 2, // Example weight, adjust as needed
            priceFeed: MockOracle(mpxPriceFeed)  // Use MockOracle instead of IDIAOracle
        }));
    }

    function addLiquidity(uint256[] memory amounts) external nonReentrant whenNotPaused returns (uint256) {
        require(amounts.length == assets.length, "Invalid input length");
        uint256 liquidityMinted = 0;
        
        if (totalLiquidity == 0) {
            liquidityMinted = 1e18; // Initial liquidity
        } else {
            liquidityMinted = type(uint256).max;
            for (uint i = 0; i < assets.length; i++) {
                uint256 assetLiquidity = (amounts[i] * totalLiquidity) / assets[i].reserve;
                if (assetLiquidity < liquidityMinted) {
                    liquidityMinted = assetLiquidity;
                }
            }
        }

        for (uint i = 0; i < assets.length; i++) {
            assets[i].token.safeTransferFrom(msg.sender, address(this), amounts[i]);
            assets[i].reserve += amounts[i];
        }

        userLiquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;

        emit LiquidityAdded(msg.sender, amounts, liquidityMinted);
        return liquidityMinted;
    }

    function removeLiquidity(uint256 liquidity) external nonReentrant whenNotPaused returns (uint256[] memory) {
        require(userLiquidity[msg.sender] >= liquidity, "Insufficient liquidity");
        uint256[] memory amounts = new uint256[](assets.length);

        for (uint i = 0; i < assets.length; i++) {
            amounts[i] = (liquidity * assets[i].reserve) / totalLiquidity;
            assets[i].reserve -= amounts[i];
            assets[i].token.safeTransfer(msg.sender, amounts[i]);
        }

        userLiquidity[msg.sender] -= liquidity;
        totalLiquidity -= liquidity;

        // Compensate for impermanent loss
        uint256 compensation = calculateImpermanentLossCompensation(liquidity);
        if (compensation > 0 && compensation <= impermanentLossFund) {
            assets[0].token.safeTransfer(msg.sender, compensation);
            impermanentLossFund -= compensation;
        }

        emit LiquidityRemoved(msg.sender, amounts, liquidity);
        return amounts;
    }
function swap(uint256 inputAssetIndex, uint256 outputAssetIndex, uint256 inputAmount, uint256 minOutputAmount) external nonReentrant whenNotPaused returns (uint256) {
    require(inputAssetIndex < assets.length && outputAssetIndex < assets.length, "Invalid asset index");
    require(inputAssetIndex != outputAssetIndex, "Cannot swap same asset");

    Asset storage inputAsset = assets[inputAssetIndex];
    Asset storage outputAsset = assets[outputAssetIndex];

    // Ensure allowance for input asset
    uint256 allowance = inputAsset.token.allowance(msg.sender, address(this));
    require(allowance >= inputAmount, "Allowance too low");

    // Transfer input asset to the contract
    require(inputAsset.token.transferFrom(msg.sender, address(this), inputAmount), "Transfer failed");
    inputAsset.reserve += inputAmount;
   
    uint256 outputAmount = calculateOutputAmount(inputAssetIndex, outputAssetIndex, inputAmount);
    require(outputAmount >= minOutputAmount, "Slippage too high");

    // Ensure enough output asset in the contract
    require(outputAsset.reserve >= outputAmount, "Insufficient output asset reserve");
    outputAsset.reserve -= outputAmount;

    // Transfer output asset to the user
    require(outputAsset.token.transfer(msg.sender, outputAmount), "Transfer failed");

    uint256 fee = calculateDynamicFee(inputAssetIndex, outputAssetIndex);
    uint256 feeAmount = (inputAmount * fee) / FEE_PRECISION;
    impermanentLossFund += feeAmount / 2; // Half of the fee goes to impermanent loss fund

    emit Swap(msg.sender, inputAssetIndex, outputAssetIndex, inputAmount, outputAmount);

    if (block.timestamp >= lastRebalanceTimestamp + rebalanceInterval) {
        rebalance();
    }

    return outputAmount;
}


    function calculateOutputAmount(uint256 inputAssetIndex, uint256 outputAssetIndex, uint256 inputAmount) public view returns (uint256) {
        Asset memory inputAsset = assets[inputAssetIndex];
        Asset memory outputAsset = assets[outputAssetIndex];

        uint256 inputValue = (inputAmount * uint256(getLatestPrice(inputAssetIndex))) / 1e8;
        uint256 outputValue = (inputValue * outputAsset.weight) / inputAsset.weight;
        uint256 outputAmount = (outputValue * 1e8) / uint256(getLatestPrice(outputAssetIndex));

        return outputAmount;
    }

    function calculateDynamicFee(uint256 inputAssetIndex, uint256 outputAssetIndex) public view returns (uint256) {
        uint256 volatility = calculateVolatility(inputAssetIndex, outputAssetIndex);
        uint256 liquidityUtilization = calculateLiquidityUtilization(inputAssetIndex, outputAssetIndex);

        uint256 dynamicFee = baseFee + (dynamicFeeRange * (volatility + liquidityUtilization) / 200);
        return dynamicFee > (baseFee + dynamicFeeRange) ? (baseFee + dynamicFeeRange) : dynamicFee;
    }

    function calculateVolatility(uint256 assetIndex1, uint256 assetIndex2) public view returns (uint256) {
        // Simplified volatility calculation. In a real-world scenario, this would be more complex.
        uint256 price1 = getLatestPrice(assetIndex1);
        uint256 price2 = getLatestPrice(assetIndex2);
        uint256 priceDiff = price1 > price2 ? price1 - price2 : price2 - price1;
        return (priceDiff * 100) / price1;
    }

    function calculateLiquidityUtilization(uint256 assetIndex1, uint256 assetIndex2) public view returns (uint256) {
        uint256 totalValue = 0;
        uint256 assetValue1 = (assets[assetIndex1].reserve * uint256(getLatestPrice(assetIndex1))) / 1e8;
        uint256 assetValue2 = (assets[assetIndex2].reserve * uint256(getLatestPrice(assetIndex2))) / 1e8;
        
        for (uint i = 0; i < assets.length; i++) {
            totalValue += (assets[i].reserve * uint256(getLatestPrice(i))) / 1e8;
        }

        return ((assetValue1 + assetValue2) * 100) / totalValue;
    }

    function calculateImpermanentLossCompensation(uint256 liquidity) public view returns (uint256) {
        // Simplified impermanent loss calculation. In a real-world scenario, this would be more complex.
        uint256 userShare = (liquidity * 1e18) / totalLiquidity;
        uint256 initialValue = 0;
        uint256 currentValue = 0;

        for (uint i = 0; i < assets.length; i++) {
            initialValue += (assets[i].reserve * uint256(getLatestPrice(i))) / 1e8;
            currentValue += (assets[i].reserve * uint256(getLatestPrice(i)) * assets[i].weight) / (1e8 * WEIGHT_PRECISION);
        }

        if (currentValue >= initialValue) {
            return 0;
        }

        uint256 loss = initialValue - currentValue;
        return (loss * userShare) / 1e18;
    }

    function rebalance() public {
        require(block.timestamp >= lastRebalanceTimestamp + rebalanceInterval, "Too soon to rebalance");
        
        uint256 totalValue = 0;
        uint256[] memory newWeights = new uint256[](assets.length);

        for (uint i = 0; i < assets.length; i++) {
            totalValue += (assets[i].reserve * uint256(getLatestPrice(i))) / 1e8;
        }

        for (uint i = 0; i < assets.length; i++) {
            newWeights[i] = ((assets[i].reserve * uint256(getLatestPrice(i))) / 1e8) * WEIGHT_PRECISION / totalValue;
            assets[i].weight = newWeights[i];
        }

        lastRebalanceTimestamp = block.timestamp;

        emit Rebalanced(newWeights);
    }

    function getLatestPrice(uint256 assetIndex) public view returns (uint256) {
        return assets[assetIndex].priceFeed.getPrice();  // Call the MockOracle's getPrice method
    }

    function setFees(uint256 _baseFee, uint256 _dynamicFeeRange) external onlyOwner {
        require(_baseFee <= FEE_PRECISION, "Base fee too high");
        require(_dynamicFeeRange <= FEE_PRECISION, "Dynamic fee range too high");

        baseFee = _baseFee;
        dynamicFeeRange = _dynamicFeeRange;

        emit FeesUpdated(_baseFee, _dynamicFeeRange);
    }

    function setRebalanceInterval(uint256 _rebalanceInterval) external onlyOwner {
        require(_rebalanceInterval >= 1 hours, "Rebalance interval too short");
        rebalanceInterval = _rebalanceInterval;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}