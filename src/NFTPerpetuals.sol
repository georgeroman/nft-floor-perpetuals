// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract NFTPerpetuals is Ownable {
    // The base currency of every payment is ETH.

    // --- Constants ---

    uint256 private constant BPS = 10e4;
    uint256 private constant SBPS = 10e6;
    uint256 private constant UNIT = 10e18;
    uint256 private constant YEAR = 360 days;

    // --- Fields ---

    // Every position must have a margin of at least 0.01 ETH
    uint256 public minMargin = 0.01 ether;

    // Pool's open interest
    uint256 public openInterest;

    // Pool's accrued fees
    uint256 public accruedFees;

    // Address of the oracle responsible for pricing and settling new orders
    address public oracle;

    // All NFTs are assumed to be on the same chain (possibly
    // different from the chain the trading contracts are on)
    struct NFT {
        // Maximum allowed leverage in units
        // - 0 = inactive
        // - 1 * 10e18 = no leverage
        // - 20 * 10e18 = 20x leverage
        uint256 maxLeverage;
        // Liquidation threshold in bps
        uint256 liquidationThreshold;
        // Fee (taken on top of the margin) in sbps
        uint256 fee;
        // Yearly interest in bps
        uint256 interest;
    }

    // Mapping from NFT contract address to details
    mapping(address => NFT) public nfts;

    enum PositionKind {
        LONG,
        SHORT
    }

    // The id of any position is `keccak256(user, nftContractAddress, positionKind)`
    struct Position {
        uint256 size;
        uint256 margin;
        // Position's entry timestamp
        uint256 timestamp;
        // Position's entry price
        uint256 price;
    }

    // Indexed by position id
    mapping(bytes32 => Position) public positions;

    enum OrderKind {
        OPEN,
        CLOSE
    }

    // Each position can have a single outstanding order (which needs to be settled by the oracle)
    struct Order {
        OrderKind kind;
        uint256 size;
        uint256 margin;
    }

    // Indexed by position id
    mapping(bytes32 => Order) public orders;

    // --- Events ---

    event OrderSubmitted(
        bytes32 indexed positionId,
        address indexed user,
        address indexed nftContractAddress,
        PositionKind positionKind,
        OrderKind orderKind,
        uint256 size,
        uint256 margin
    );

    event PositionUpdated(
        bytes32 indexed positionId,
        address indexed user,
        address indexed nftContractAddress,
        PositionKind positionKind,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 fee
    );

    event PositionClosed(
        bytes32 indexed positionId,
        address indexed user,
        address indexed nftContractAddress,
        PositionKind positionKind,
        uint256 size,
        uint256 margin,
        uint256 price,
        uint256 fee,
        int256 pnl,
        bool liquidated
    );

    // --- Constructor ---

    constructor(address owner, address oracleAddress) {
        _transferOwnership(owner);

        oracle = oracleAddress;
    }

    receive() external payable {
        // Receive ETH
    }

    // --- Public ---

    function submitOpenOrder(
        address nftContractAddress,
        PositionKind positionKind,
        uint256 size,
        uint256 margin
    ) external payable {
        require(margin >= minMargin, "Below mininum margin");

        bytes32 positionId = getPositionId(
            msg.sender,
            nftContractAddress,
            positionKind
        );

        Order storage order = orders[positionId];
        require(order.size == 0, "Order already exists");

        NFT storage nft = nfts[nftContractAddress];

        // Compute the position's leverage from its margin and size
        uint256 leverage = (size * UNIT) / margin;
        require(
            leverage >= UNIT && leverage <= nft.maxLeverage,
            "Invalid leverage"
        );

        // Compute the fee and proceed with payment
        uint256 fee = (size * nft.fee) / 10e6;
        require(msg.value == margin + fee, "Invalid payment");

        // Update the pool's open interest
        _updateOpenInterest(size, OrderKind.OPEN);
        require(
            getPoolUtilization() < BPS,
            "Maximum pool utilization exceeded"
        );

        // Save the position's outstanding order (will need to be settled by the oracle)
        orders[positionId] = Order({
            kind: OrderKind.OPEN,
            size: size,
            margin: margin
        });

        emit OrderSubmitted(
            positionId,
            msg.sender,
            nftContractAddress,
            positionKind,
            OrderKind.OPEN,
            size,
            margin
        );
    }

    function submitCloseOrder(
        address nftContractAddress,
        PositionKind positionKind,
        uint256 size
    ) external payable {
        require(size > 0, "Size cannot be zero");

        bytes32 positionId = getPositionId(
            msg.sender,
            nftContractAddress,
            positionKind
        );

        Order storage order = orders[positionId];
        require(order.size == 0, "Order already exists");

        // Fetch the corresponding position's details
        Position storage position = positions[positionId];
        require(position.margin > 0, "No corresponding position");

        // Can close at most the position's size
        if (size > position.size) {
            size = position.size;
        }

        NFT storage nft = nfts[nftContractAddress];
        uint256 fee = (size * nft.fee) / SBPS;
        require(msg.value == fee, "Invalid payment");

        // Compute the margin amount associated to the closed size
        uint256 margin = (size * position.margin) / position.size;

        // Save the position's outstanding order (will need to be settled by the oracle)
        orders[positionId] = Order({
            kind: OrderKind.CLOSE,
            size: size,
            margin: margin
        });

        emit OrderSubmitted(
            positionId,
            msg.sender,
            nftContractAddress,
            positionKind,
            OrderKind.CLOSE,
            size,
            margin
        );
    }

    function cancelOrder(address nftContractAddress, PositionKind positionKind)
        external
    {
        bytes32 positionId = getPositionId(
            msg.sender,
            nftContractAddress,
            positionKind
        );

        Order storage order = orders[positionId];
        require(order.size > 0, "Order does not exist");

        NFT storage nft = nfts[nftContractAddress];
        uint256 fee = (order.size * nft.fee) / SBPS;

        // Mark the order as deleted
        delete orders[positionId];

        // Refund the fee and (optionally) the margin paid when submitting the order
        uint256 amount = fee;
        if (order.kind == OrderKind.OPEN) {
            _updateOpenInterest(order.size, order.kind);
            amount += order.margin;
        }

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Could not send payment");
    }

    // --- Oracle ---

    function settleOrder(
        address user,
        address nftContractAddress,
        PositionKind positionKind,
        uint256 quotedPrice
    ) external {
        require(msg.sender == oracle, "Unauthorized");

        bytes32 positionId = getPositionId(
            user,
            nftContractAddress,
            positionKind
        );

        Order storage order = orders[positionId];
        require(order.size > 0, "Order does not exist");

        // Handle fees
        NFT storage nft = nfts[nftContractAddress];
        uint256 fee = (order.size * nft.fee) / SBPS;
        accruedFees += fee;

        Position storage position = positions[positionId];
        if (order.kind == OrderKind.OPEN) {
            // Take the size-weighted average of the previous position and the new order
            uint256 averagePrice = (position.size *
                position.price +
                order.size *
                quotedPrice) / (position.size + order.size);

            // Update the position's entry timestamp if it's the first time we encounter it
            if (position.timestamp == 0) {
                position.timestamp = block.timestamp;
            }

            // Update the position's details
            position.size += order.size;
            position.margin += order.margin;
            position.price = averagePrice;

            // Mark the order as settled
            delete orders[positionId];

            emit PositionUpdated(
                positionId,
                user,
                nftContractAddress,
                positionKind,
                position.size,
                position.margin,
                position.price,
                fee
            );
        } else {
            require(position.margin > 0, "No corresponding position");

            int256 pnl = _getPnL(
                positionKind,
                quotedPrice,
                position.price,
                order.size,
                nft.interest,
                position.timestamp
            );

            uint256 margin = order.margin;
            uint256 size = order.size;
            if (
                pnl <=
                -1 * int256((position.margin * nft.liquidationThreshold) / BPS)
            ) {
                // Fully close the position if it is liquidatable
                pnl = -1 * int256(position.margin);
                margin = position.margin;
                size = position.size;
                position.margin = 0;
            } else {
                position.margin -= margin;
                position.size -= size;
            }

            if (position.margin == 0) {
                delete positions[positionId];
            }
            delete orders[positionId];

            if (pnl < 0) {
                // User is at loss
                uint256 positivePnl = uint256(-1 * pnl);
                if (margin > positivePnl) {
                    (bool success, ) = payable(msg.sender).call{
                        value: margin - positivePnl
                    }("");
                    require(success, "Could not send payment");
                }
            } else {
                (bool success, ) = payable(msg.sender).call{
                    value: margin + uint256(pnl)
                }("");
                require(success, "Could not send payment");
            }

            _updateOpenInterest(size, order.kind);

            emit PositionClosed(
                positionId,
                user,
                nftContractAddress,
                positionKind,
                size,
                margin,
                quotedPrice,
                fee,
                pnl,
                false
            );
        }
    }

    // --- Owner ---

    function setNFT(address contractAddress, NFT memory nft) public onlyOwner {
        nfts[contractAddress].maxLeverage = nft.maxLeverage;
        nfts[contractAddress].liquidationThreshold = nft.liquidationThreshold;
        nfts[contractAddress].fee = nft.fee;
        nfts[contractAddress].interest = nft.interest;
    }

    function removeNFT(address contractAddress) public onlyOwner {
        delete nfts[contractAddress];
    }

    // --- Utils ---

    function getPositionId(
        address user,
        address nftContractAddress,
        PositionKind positionKind
    ) public pure returns (bytes32 positionId) {
        positionId = keccak256(
            abi.encodePacked(user, nftContractAddress, positionKind)
        );
    }

    function getPoolUtilization() public view returns (uint256 utilization) {
        uint256 balance = address(this).balance;
        utilization = balance == 0 ? 0 : (openInterest * 100) / balance;
    }

    // --- Internal ---

    function _updateOpenInterest(uint256 amount, OrderKind orderKind) internal {
        if (orderKind == OrderKind.CLOSE) {
            openInterest -= (openInterest <= amount) ? openInterest : amount;
        } else {
            openInterest += amount;
        }
    }

    function _getPnL(
        PositionKind positionKind,
        uint256 quotedPrice,
        uint256 positionPrice,
        uint256 size,
        uint256 interest,
        uint256 timestamp
    ) internal view returns (int256) {
        uint256 pnl;
        bool pnlIsNegative;

        if (positionKind == PositionKind.LONG) {
            // Long positions will profit from the price going up relative to the position's price.
            if (quotedPrice >= positionPrice) {
                // Profit scenario
                pnl = (size * (quotedPrice - positionPrice)) / positionPrice;
            } else {
                // Loss scenario
                pnl = (size * (positionPrice - quotedPrice)) / positionPrice;
                pnlIsNegative = true;
            }
        } else {
            // Short positions will profit from the price going down relative to the position's price.
            if (quotedPrice > positionPrice) {
                // Loss scenario
                pnl = (size * (quotedPrice - positionPrice)) / positionPrice;
                pnlIsNegative = true;
            } else {
                // Profit scenario
                pnl = (size * (positionPrice - quotedPrice)) / positionPrice;
            }
        }

        // Subtract interest payments
        if (block.timestamp >= timestamp + 15 minutes) {
            uint256 interestAmount = (size *
                interest *
                (block.timestamp - timestamp)) / (BPS * YEAR);

            if (pnlIsNegative) {
                pnl += interestAmount;
            } else if (pnl < interestAmount) {
                pnl = interestAmount - pnl;
                pnlIsNegative = true;
            } else {
                pnl -= interestAmount;
            }
        }

        if (pnlIsNegative) {
            return -1 * int256(pnl);
        } else {
            return int256(pnl);
        }
    }
}
