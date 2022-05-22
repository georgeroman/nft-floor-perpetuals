// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IOracle {
    function getPrice(address feed) external view returns (uint256);
    function getLastNPrices(address token, uint256 lastN)
        external
        view
        returns (uint256[] memory);
}