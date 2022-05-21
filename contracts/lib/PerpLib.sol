// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IOracle.sol";
import '../interfaces/IFeeCalculator.sol';

library PerpLib {
    uint256 public constant BASE = 10**8;

    function _canTakeProfit(
        bool isLong,
        uint256 positionTimestamp,
        uint256 positionOraclePrice,
        uint256 oraclePrice,
        uint256 minPriceChange,
        uint256 minProfitTime
    ) internal view returns(bool) {
        if (block.timestamp > positionTimestamp + minProfitTime) {
            return true;
        } else if (isLong && oraclePrice > positionOraclePrice * (1e4 + minPriceChange) / 1e4) {
            return true;
        } else if (!isLong && oraclePrice < positionOraclePrice * (1e4 - minPriceChange) / 1e4) {
            return true;
        }
        return false;
    }

    function _checkLiquidation(
        bool isLong,
        uint256 positionPrice,
        uint256 positionLeverage,
        uint256 price,
        uint256 liquidationThreshold
    ) internal pure returns (bool) {

        uint256 liquidationPrice;
        if (isLong) {
            liquidationPrice = positionPrice - positionPrice * liquidationThreshold * 10**4 / positionLeverage;
        } else {
            liquidationPrice = positionPrice + positionPrice * liquidationThreshold * 10**4 / positionLeverage;
        }

        if (isLong && price <= liquidationPrice || !isLong && price >= liquidationPrice) {
            return true;
        } else {
            return false;
        }
    }

    function _getPnl(
        bool isLong,
        uint256 positionPrice,
        uint256 positionLeverage,
        uint256 margin,
        uint256 price
    ) internal view returns(int256 _pnl) {
        bool pnlIsNegative;
        uint256 pnl;
        if (isLong) {
            if (price >= positionPrice) {
                pnl = margin * positionLeverage * (price - positionPrice) / positionPrice / BASE;
            } else {
                pnl = margin * positionLeverage * (positionPrice - price) / positionPrice / BASE;
                pnlIsNegative = true;
            }
        } else {
            if (price > positionPrice) {
                pnl = margin * positionLeverage * (price - positionPrice) / positionPrice / BASE;
                pnlIsNegative = true;
            } else {
                pnl = margin * positionLeverage * (positionPrice - price) / positionPrice / BASE;
            }
        }

        if (pnlIsNegative) {
            _pnl = -1 * int256(pnl);
        } else {
            _pnl = int256(pnl);
        }

        return _pnl;
    }

    function _getTradeFee(
        uint256 margin,
        uint256 leverage,
        uint256 fee,
        address productToken,
        address user,
        address feeCalculator
    ) internal view returns(uint256) {
        int256 dynamicFee = IFeeCalculator(feeCalculator).getFee(productToken, user);
        fee = dynamicFee > 0 ? fee + uint256(dynamicFee) : fee - uint256(-1*dynamicFee);
        return margin * leverage / BASE * fee / 10**4;
    }
}