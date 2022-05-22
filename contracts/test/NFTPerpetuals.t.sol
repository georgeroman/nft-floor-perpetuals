// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.13;

// import {Test} from "forge-std/Test.sol";
// import "forge-std/console.sol";

// import {Exchange} from "../Exchange.sol";
// import {TrustusPacket} from "../interfaces/trustus/TrustusPacket.sol";

// contract ExchangeTest is Test {
//     Exchange public exchange;

//     address public nftContract = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D; // BAYC NFT

//     address public owner = vm.addr(0x02);
//     address public oracle = 0x32dA57E736E05f75aa4FaE2E9Be60FD904492726; // Reservoir oracle
//     address public alice = vm.addr(0x04);

//     event LogNFTProduct(Exchange.NFTProduct);
//     // --- Set up --- // 

//     function setUp() public {
//         exchange = new Exchange(owner, oracle);

//         vm.prank(owner);
//         exchange.addNFTProduct(
//             nftContract,
//             Exchange.NFTProduct({
//                 // 20x
//                 maxLeverage: 20 * 10e18,
//                 // 80%
//                 liquidationThreshold: 8000,
//                 // 0.001%
//                 fee: 10,
//                 // 0.15%
//                 interest: 15,
//                 // 50%
//                 maxExposureWeight: 5000,
//                 // 100 eth
//                 reserve: 100 ether,
//                 // 6%
//                 openInterestLong: 600,
//                 // 7%
//                 openInterestShort: 70
//             })
//         );
//     }

//     // --- Helpers ---

//     function testgetNFT() public returns (Exchange.NFTProduct memory nft){
//         (
//             uint256 maxLeverage,
//             uint256 liquidationThreshold,
//             uint256 fee,
//             uint256 interest,
//             uint256 maxExposureWeight,
//             uint256 reserve,
//             uint256 openInterestLong,
//             uint256 openInterestShort
//         ) = exchange.nftProducts(nftContract);
//         nft.maxLeverage = maxLeverage;
//         nft.liquidationThreshold = liquidationThreshold;
//         nft.fee = fee;
//         nft.interest = interest;
//         nft.maxExposureWeight = maxExposureWeight;
//         nft.reserve = reserve;
//         nft.openInterestLong = openInterestLong;
//         nft.openInterestShort = openInterestShort;
//         emit LogNFTProduct(nft);
//         assertTrue(nft.reserve != 0);
//     }

//     function testOpenPosition() public {
//         vm.warp(block.timestamp - 10 days);
//         bytes32 positionId = exchange.openPosition(
//             nftContract,
//             Exchange.PositionKind.LONG,
//             1 ether,
//             5,
//             uint256(9844836),
//             TrustusPacket(
//                 bytes32(0x9dc1160e2552726584981f9d51940a705dfdc6ccb2e27e9277a1bc8cd0e98887),
//                 1653035559,
//                 bytes("0x000000000000000000000000000000000000000000000005563ed89e48d0e698"),
//                 uint8(27),
//                 bytes32(0xd9d99da8f7c45483051784eea32f4b0c9cab146b0859e3b5f46a149305300bfb),
//                 bytes32(0x612b1cd200c5e1fa3fc8e6a47665296cb7615976d6da06ae5693e52cf132e078)
//             )
//         );
//         emit log_bytes32(positionId);
//     }

//     // function getOrder(bytes32 positionId) public view returns (Exchange.Order memory order) {
//     //     (
//     //         Exchange.OrderKind kind,
//     //         uint256 size,
//     //         uint256 margin
//     //     ) = exchange.positions(positionId);
//     //     order.kind = kind;
//     //     order.size = size;
//     //     order.margin = margin;
//     // }

//     // function getPosition(bytes32 positionId) public view returns (Exchange.Position memory position) {
//     //     bytes32 positionId = exchange.getPositionId(owner, nftContract, Exchange.PositionKind.LONG);
//     //     (
//     //         uint256 size,
//     //         uint256 margin,
//     //         uint256 timestamp,
//     //         uint256 price
//     //     ) = exchange.positions(positionId);
//     //     position.size = size;
//     //     position.margin = margin;
//     //     position.timestamp = timestamp;
//     //     position.price = price;
//     // }

//     // // --- Tests ---

//     // function testSubmitOpenOrder() public {
//     //     uint256 size = 5 ether;
//     //     uint256 margin = 1 ether;

//     //     Exchange.NFT memory nft = getNFT(nftContract);
//     //     uint256 fee = (size * nft.fee) / 10e6;

//     //     vm.deal(alice, 10 ether);
//     //     vm.prank(alice);
//     //     exchange.submitOpenOrder{value: margin + fee}(
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         size,
//     //         margin
//     //     );

//     //     assert(address(exchange).balance == margin + fee);

//     //     bytes32 positionId = exchange.getPositionId(
//     //         alice,
//     //         nftContract,
//     //         Exchange.PositionKind.LONG
//     //     );

//     //     Exchange.Order memory order = getOrder(positionId);
//     //     assert(order.kind == Exchange.OrderKind.OPEN);
//     //     assert(order.size == size);
//     //     assert(order.margin == margin);
//     // }

//     // function testSettleOpenOrder() public {
//     //     uint256 size = 5 ether;
//     //     uint256 margin = 1 ether;

//     //     Exchange.NFT memory nft = getNFT(nftContract);
//     //     uint256 fee = (size * nft.fee) / 10e6;

//     //     vm.deal(alice, 10 ether);
//     //     vm.prank(alice);
//     //     exchange.submitOpenOrder{value: margin + fee}(
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         size,
//     //         margin
//     //     );

//     //     uint256 quotedPrice = 1 ether;

//     //     vm.prank(oracle);
//     //     exchange.settleOrder(
//     //         alice,
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         quotedPrice
//     //     );

//     //     bytes32 positionId = exchange.getPositionId(
//     //         alice,
//     //         nftContract,
//     //         Exchange.PositionKind.LONG
//     //     );

//     //     Exchange.Order memory order = getOrder(positionId);
//     //     assert(order.size == 0);

//     //     Exchange.Position memory position = getPosition(positionId);
//     //     assert(position.size == size);
//     //     assert(position.margin == margin);
//     //     assert(position.price == quotedPrice);
//     // }

//     // function testCloseOrderWithLoss() public {
//     //     uint256 openSize = 5 ether;
//     //     uint256 margin = 1 ether;

//     //     Exchange.NFT memory nft = getNFT(nftContract);
//     //     uint256 openFee = (openSize * nft.fee) / 10e6;

//     //     vm.deal(alice, 10 ether);

//     //     // Submit order to open position
//     //     vm.prank(alice);
//     //     exchange.submitOpenOrder{value: margin + openFee}(
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         openSize,
//     //         margin
//     //     );

//     //     uint256 openPrice = 1 ether;

//     //     // Have the oracle settle the order
//     //     vm.prank(oracle);
//     //     exchange.settleOrder(
//     //         alice,
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         openPrice
//     //     );

//     //     vm.warp(block.timestamp + 7 days);

//     //     uint256 closeSize = openSize / 2;
//     //     uint256 closeFee = (closeSize * nft.fee) / 10e6;

//     //     // Submit order to partially close position
//     //     vm.prank(alice);
//     //     exchange.submitCloseOrder{value: closeFee}(
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         closeSize
//     //     );

//     //     uint256 closePrice = 0.98 ether;

//     //     bytes32 positionId = exchange.getPositionId(
//     //         alice,
//     //         nftContract,
//     //         Exchange.PositionKind.LONG
//     //     );

//     //     // We expect a loss since closePrice < openPrice
//     //     Exchange.Position memory position = getPosition(positionId);
//     //     int256 pnl = exchange.getPnL(
//     //         Exchange.PositionKind.LONG,
//     //         closePrice,
//     //         position.price,
//     //         closeSize,
//     //         nft.interest,
//     //         position.timestamp
//     //     );
//     //     uint256 marginClosed = closeSize * position.margin / position.size;

//     //     // Have the oracle settle the order
//     //     vm.prank(oracle);
//     //     exchange.settleOrder(
//     //         alice,
//     //         nftContract,
//     //         Exchange.PositionKind.LONG,
//     //         closePrice
//     //     );

//     //     assert(address(exchange).balance == margin - marginClosed + openFee + closeFee + uint256(-pnl));
//     // }
// }
