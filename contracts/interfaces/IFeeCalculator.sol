pragma solidity ^0.8.0;

interface IFeeCalculator {
    function getFee(address token, address oracle)
        external
        view
        returns (int256);
}
