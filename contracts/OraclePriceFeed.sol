// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Owned} from "solmate/auth/Owned.sol";

contract OracleFeedConsumer is Owned {
    uint256 public constant TIME_TO_STALE = 60 minutes;

    uint256 public lastTimestamp;
    uint256 public maxTimeDifference;

    address internal keeper;

    mapping(address => address) public nftPriceFeeds;
    mapping(address => uint256) public nftPrices;

    constructor() Owned(msg.sender) {
        maxTimeDifference = TIME_TO_STALE;
    }

    // -- GETTERS --

    function getPrice(address token) public view returns (uint256) {
        // require(
        //     block.timestamp - lastTimestamp > maxTimeDifference,
        //     "!price-stale"
        // );

        return nftPrices[token];
    }

    /// @notice Returns the address of the price feed
    /// @return Price feed address
    function getPriceFeedForToken(address token)
        public
        view
        returns (AggregatorV3Interface)
    {
        return AggregatorV3Interface(nftPriceFeeds[token]);
    }

    // -- INTERNAL --

    function getChainlinkPrice(address token)
        internal
        view
        returns (uint256, uint256)
    {
        AggregatorV3Interface feed = AggregatorV3Interface(
            nftPriceFeeds[token]
        );
        (, int256 price, , uint256 timestamp, ) = feed.latestRoundData();

        require(price > 0, "!chainlink-price");

        return (uint256(price), timestamp);
    }

    // -- KEEPER FUNCTIONS --

    function setOracleForNft(address token, address feed) external onlyKeeper {
        nftPriceFeeds[token] = feed;
    }

    function setPriceForToken(address token) external onlyKeeper {
        (uint256 price, uint256 timestamp) = getChainlinkPrice(token);
        nftPrices[token] = price;
        lastTimestamp = timestamp;
    }

    // -- OWNER FUNCTIONS --

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper, "!keeper-only");
        _;
    }
}
