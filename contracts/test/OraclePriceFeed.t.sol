// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "../OraclePriceFeed.sol";
import "./mocks/MockAggregator.sol";

import {Test} from "forge-std/Test.sol";

contract OracleFeedConsumerTest is Test {
    uint8 public constant DECIMALS = 18;
    int256 public constant INITIAL_ANSWER = 1 * 10**18;

    OracleFeedConsumer public priceFeedConsumer;
    MockV3Aggregator public mockV3Aggregator;

    address public nftContract = vm.addr(0x01);
    address public owner = vm.addr(0x02);
    address public keeper = vm.addr(0x03);

    function setUp() public {
        vm.startPrank(owner);
        mockV3Aggregator = new MockV3Aggregator(DECIMALS, INITIAL_ANSWER);
        priceFeedConsumer = new OracleFeedConsumer();
        priceFeedConsumer.setKeeper(keeper);
        vm.stopPrank();

        emit log_named_address("keeper", keeper);

        vm.prank(keeper);
        priceFeedConsumer.setOracleForNft(
            nftContract,
            address(mockV3Aggregator)
        );
    }

    function testOracleUpdatesValue() public {
        int256 newPrice = 3 * 10**18;

        uint256 price = priceFeedConsumer.getPrice(nftContract);
        emit log_named_uint("INIITAL PRICE", price);
        assertEq(price, 0);

        mockV3Aggregator.updateAnswer(newPrice);

        vm.expectRevert("!keeper-only");
        priceFeedConsumer.setPriceForToken(nftContract);

        vm.prank(keeper);
        priceFeedConsumer.setPriceForToken(nftContract);

        uint256 updatedPrice = priceFeedConsumer.getPrice(nftContract);
        assertEq(updatedPrice, uint256(newPrice));
    }
}
