// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IOracle.sol";

contract FeeCalculator {
    // Base factor for the fee calculation
    uint256 public constant PRICE_BASE = 10000;

    // Regularization factor for the fee calculation
    uint256 weightDecay;

    // Max deviation ratio threshold
    uint256 threshold;

    // Max fee we want to charge a user position
    uint256 public maxDynamicFee = 50; // 0.5%

    // Last N prices we want to compute the volatility for
    uint256 lastN = 3;

    constructor(uint256 _weightDecay, uint256 _threshold) {
        weightDecay = _weightDecay;
        threshold = _threshold;
    }

    // Dynamic fee updated based on the volatility of the previous prices
    function getFee(address token, address oracle)
        public
        view
        returns (int256)
    {
        uint256[] memory prices = IOracle(oracle).getLastNPrices(token, lastN);
        uint256 dynamicFee = 0;

        for (uint256 i = prices.length - 1; i > 0; i--) {
            dynamicFee = (dynamicFee * weightDecay) / PRICE_BASE;
            uint256 deviation = _calcDeviation(
                prices[i - 1],
                prices[i],
                threshold
            );
            dynamicFee += deviation;
        }
        dynamicFee = dynamicFee > maxDynamicFee ? maxDynamicFee : dynamicFee;
        return int256(dynamicFee);
    }

    // Calculate deviation ratio/ of previous and current price
    function _calcDeviation(
        uint256 price,
        uint256 previousPrice,
        uint256 _threshold
    ) internal pure returns (uint256) {
        if (previousPrice == 0) {
            return 0;
        }
        uint256 absDelta = price > previousPrice
            ? price - previousPrice
            : previousPrice - price;
        uint256 deviationRatio = (absDelta * PRICE_BASE) / previousPrice;
        return deviationRatio > _threshold ? deviationRatio - _threshold : 0;
    }
}
