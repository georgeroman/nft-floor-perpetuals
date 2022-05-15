// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {NFTPerpetuals} from "../src/NFTPerpetuals.sol";

contract NFTPerpetualsTest is Test {
    NFTPerpetuals public exchange;

    address public nftContract = vm.addr(0x01);

    address public owner = vm.addr(0x02);
    address public oracle = vm.addr(0x03);
    address public alice = vm.addr(0x04);

    // --- Set up ---

    function setUp() public {
        exchange = new NFTPerpetuals(owner, oracle);

        vm.prank(owner);
        exchange.setNFT(
            nftContract,
            NFTPerpetuals.NFT({
                // 20x
                maxLeverage: 20 * 10e18,
                // 80%
                liquidationThreshold: 8000,
                // 0.001%
                fee: 10,
                // 0.15%
                interest: 15
            })
        );
    }

    // --- Helpers ---

    function getNFT(address nftContractAddress) public view returns (NFTPerpetuals.NFT memory nft) {
        (uint256 maxLeverage, uint256 liquidationThreshold, uint256 fee, uint256 interest) = exchange.nfts(nftContractAddress);
        nft.maxLeverage = maxLeverage;
        nft.liquidationThreshold = liquidationThreshold;
        nft.fee = fee;
        nft.interest = interest;
    }

    function getOrder(bytes32 positionId) public view returns (NFTPerpetuals.Order memory order) {
        (NFTPerpetuals.OrderKind kind, uint256 size, uint256 margin) = exchange.orders(positionId);
        order.kind = kind;
        order.size = size;
        order.margin = margin;
    }

    // --- Tests ---

    function testSubmitOpenOrder() public {
        uint256 size = 5 ether;
        uint256 margin = 1 ether;

        NFTPerpetuals.NFT memory nft = getNFT(nftContract);
        uint256 fee = (size * nft.fee) / 10e6;

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        exchange.submitOpenOrder{value: margin + fee}(
            nftContract,
            NFTPerpetuals.PositionKind.LONG,
            size,
            margin
        );

        bytes32 positionId = exchange.getPositionId(
            alice,
            nftContract,
            NFTPerpetuals.PositionKind.LONG
        );

        NFTPerpetuals.Order memory order = getOrder(positionId);
        assert(order.kind == NFTPerpetuals.OrderKind.OPEN);
        assert(order.size == size);
        assert(order.margin == margin);
    }
}
