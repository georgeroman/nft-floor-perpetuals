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
        // TODO: Add time stale verification
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
        require(nftPriceFeeds[token] != address(0), "!empty-address");
        return AggregatorV3Interface(nftPriceFeeds[token]);
    }

    function getTwapPrice(address token, uint256 interval)
        external
        view
        returns (uint256)
    {
        AggregatorV3Interface aggregator = getPriceFeedForToken(token);
        require(interval != 0, "!interval");

        (
            uint80 round,
            uint256 latestPrice,
            uint256 latestTimestamp
        ) = getChainlinkLatestRoundData(aggregator);

        uint256 baseTimestamp = block.timestamp - interval;

        if (lastTimestamp < baseTimestamp || round == 0) {
            return latestPrice;
        }

        uint256 previousTimestamp = latestTimestamp;
        uint256 cumulativeTime = block.timestamp - previousTimestamp;
        uint256 weightedPrice = latestPrice * cumulativeTime;

        while (true) {
            if (round == 0) {
                return weightedPrice / cumulativeTime;
            }

            round = round - 1;

            (
                ,
                uint256 currentPrice,
                uint256 currentTimestamp
            ) = getChainlinkRoundData(aggregator, round);

            if (currentTimestamp <= baseTimestamp) {
                weightedPrice =
                    weightedPrice +
                    currentPrice *
                    (previousTimestamp - baseTimestamp);
                break;
            }

            uint256 timeFraction = previousTimestamp - currentTimestamp;
            weightedPrice = weightedPrice + currentPrice * timeFraction;
            cumulativeTime = cumulativeTime + timeFraction;
            previousTimestamp = currentTimestamp;
        }

        return weightedPrice / interval;
    }

    // -- INTERNAL --

    function getChainlinkPrice(address token)
        internal
        view
        returns (uint256, uint256)
    {
        //TODO: Update decimals
        AggregatorV3Interface feed = AggregatorV3Interface(
            nftPriceFeeds[token]
        );
        (, int256 price, , uint256 timestamp, ) = feed.latestRoundData();

        require(price > 0, "!chainlink-price");

        return (uint256(price), timestamp);
    }

    function getChainlinkLatestRoundData(AggregatorV3Interface _aggregator)
        internal
        view
        returns (
            uint80,
            uint256 finalPrice,
            uint256
        )
    {
        (
            uint80 round,
            int256 latestPrice,
            ,
            uint256 latestTimestamp,

        ) = _aggregator.latestRoundData();
        finalPrice = uint256(latestPrice);
        // if (latestPrice < 0) { // TODO: Not sure why price can be negative
        //     require(round > 0, "!round");
        //     (round, finalPrice, latestTimestamp) = getRoundData(
        //         _aggregator,
        //         round - 1
        //     );
        // }
        return (round, finalPrice, latestTimestamp);
    }

    function getChainlinkRoundData(
        AggregatorV3Interface _aggregator,
        uint80 _round
    )
        internal
        view
        returns (
            uint80,
            uint256,
            uint256
        )
    {
        (
            uint80 round,
            int256 latestPrice,
            ,
            uint256 latestTimestamp,

        ) = _aggregator.getRoundData(_round);
        return (round, uint256(latestPrice), latestTimestamp);
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
