// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {TrustusPacket} from "./interfaces/trustus/TrustusPacket.sol";

import {Pool} from "./Pool.sol";

contract Exchange is Owned {
    // The base currency of every payment is ETH

    // --- Structs and Enums ---

    enum PositionKind {
        LONG,
        SHORT
    }

    enum OrderKind {
        OPEN,
        CLOSE
    }

    // Each NFT available for trading has a corresponding `NFTProduct` struct.
    // All traded NFTs are assumed to be on the same chain (might be different
    // from the exchange's deployment chain).
    struct NFTProduct {
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
        // Share of the max exposure across all products
        uint256 maxExposureWeight;
        // Virtual ETH reserve, used to compute slippage
        uint256 reserve;
        // Open interest by position kind
        uint256 openInterestLong;
        uint256 openInterestShort;
    }

    // Each user can have at most two active positions on any particular NFT
    // (a long position and/or a short position). The id of any position can
    // be computed via `keccak256(user, nft, kind)`.
    struct Position {
        uint256 margin;
        uint256 leverage;
        uint256 timestamp;
        uint256 price;
    }

    // --- Constants ---

    uint256 private constant BPS = 10e4;
    uint256 private constant SBPS = 10e6;
    uint256 private constant UNIT = 10e18;
    uint256 private constant YEAR = 360 days;

    WETH public immutable weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    bytes32 public immutable DOMAIN_SEPARATOR =
        keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SingleUserBackedLendingVault"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );

    // --- Fields ---

    // Every position must have a margin of at least 0.01 ETH
    uint256 public minMargin = 0.01 ether;

    // Pool's total open interest
    uint256 public totalOpenInterest;

    // Pool's total max exposure weight
    uint256 public totalMaxExposureWeight;

    // Pool's max exposure multiplier
    uint256 public exposureMultiplier;

    // Pool's balance utilization multiplier
    uint256 public utilizationMultiplier;

    // Used to adjust the price to balance longs and shorts
    uint256 public maxShift = 0.003e8;

    // Trusted address of the oracle responsible for pricing and settling new orders
    address public oracle;

    // Address of the pool that handles liquidity provision
    address public pool;

    // Mapping from NFT contract address to tradeable NFT product details
    mapping(address => NFTProduct) public nftProducts;

    // Indexed by position id
    mapping(bytes32 => Position) public positions;

    // --- Events ---

    event NFTProductAdded(address nftContractAddress);
    event NFTProductRemoved(address nftContractAddress);

    // --- Constructor ---

    constructor(address ownerAddress, address oracleAddress)
        Owned(ownerAddress)
    {
        oracle = oracleAddress;
        pool = address(new Pool(address(this)));
    }

    // --- Public ---

    function openPosition(
        address nftContractAddress,
        PositionKind positionKind,
        uint256 margin,
        uint256 leverage,
        uint256 oraclePrice,
        TrustusPacket calldata packet
    ) public payable returns (bytes32 positionId) {
        // TODO: Pass and validate TrustUs message instead of passing the oracle price directly
        require(packet.deadline >= block.timestamp, "Packet expired");
        require(
            packet.request ==
                keccak256(
                    abi.encodePacked(
                        "twap",
                        "contract",
                        loan.collateralContractAddress
                    )
                ),
            "Invalid packet"
        );

        // Validate the Trustus packet's signature.
        address signer = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR,
                    keccak256(
                        abi.encode(
                            keccak256(
                                "VerifyPacket(bytes32 request,uint256 deadline,bytes payload)"
                            ),
                            packet.request,
                            packet.deadline,
                            keccak256(packet.payload)
                        )
                    )
                )
            ),
            packet.v,
            packet.r,
            packet.s
        );
        require(signer == oracle, "Unauthorized signer");
        
        require(margin >= minMargin, "Invalid margin");
        
        NFTProduct storage nftProduct = nftProducts[nftContractAddress];
        require(
            leverage >= UNIT && leverage <= nftProduct.maxLeverage,
            "Invalid leverage"
        );

        // TODO: Integrate dynamic fees
        // The fee is computed based on the total amount and taken on top of the margin
        uint256 amount = (margin * leverage) / UNIT;
        uint256 fee = (amount * nftProduct.fee) / SBPS;
        // TODO: Execute the payment

        // Fetch the price quoted by the exchange
        uint256 price = _calculatePrice(
            positionKind,
            nftProduct.openInterestLong,
            nftProduct.openInterestShort,
            // Each individual NFT product has available only a share of the pool's total balance
            (Pool(payable(pool)).totalAssets() *
                nftProduct.maxExposureWeight *
                exposureMultiplier) /
                totalMaxExposureWeight /
                BPS,
            nftProduct.reserve,
            amount,
            oraclePrice
        );

        _updateOpenInterest(
            nftContractAddress,
            PositionKind.LONG,
            OrderKind.OPEN,
            amount
        );

        positionId = getPositionId(
            msg.sender,
            nftContractAddress,
            positionKind
        );

        Position storage position = positions[positionId];

        uint256 timestamp = block.timestamp;
        if (position.margin > 0) {
            // When updating an existing position, update some fields to their size-weighted averages
            timestamp =
                (position.margin *
                    position.timestamp +
                    margin *
                    block.timestamp) /
                (position.margin * margin);
            price =
                (position.margin *
                    position.leverage *
                    position.price +
                    margin *
                    leverage *
                    price) /
                (position.margin * position.leverage + margin * leverage);
            leverage =
                (position.margin * position.leverage + margin * leverage) /
                (position.margin + margin);

            margin = position.margin + margin;
        }

        positions[positionId] = Position({
            margin: margin,
            leverage: leverage,
            price: price,
            timestamp: timestamp
        });

        // TODO: Emit event
    }

    // --- Owner ---

    function addNFTProduct(
        address nftContractAddress,
        NFTProduct memory nftProduct
    ) public onlyOwner {
        require(
            nftProducts[nftContractAddress].liquidationThreshold == 0,
            "NFT product already exists"
        );
        require(
            nftProduct.liquidationThreshold != 0,
            "Zero liquidation threshold"
        );

        NFTProduct storage product = nftProducts[nftContractAddress];
        product.maxLeverage = nftProduct.maxLeverage;
        product.liquidationThreshold = nftProduct.liquidationThreshold;
        product.fee = nftProduct.fee;
        product.interest = nftProduct.interest;
        product.maxExposureWeight = nftProduct.maxExposureWeight;
        product.reserve = nftProduct.reserve;
        product.openInterestLong = 0;
        product.openInterestShort = 0;

        totalMaxExposureWeight += nftProduct.maxExposureWeight;

        emit NFTProductAdded(nftContractAddress);
    }

    function removeNFTProduct(address nftContractAddress) public onlyOwner {
        require(
            nftProducts[nftContractAddress].liquidationThreshold != 0,
            "NFT product does not exist"
        );

        totalMaxExposureWeight -= nftProducts[nftContractAddress]
            .maxExposureWeight;

        delete nftProducts[nftContractAddress];

        emit NFTProductRemoved(nftContractAddress);
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

    // --- Internal ---

    function _depositToPool(uint256 amount) internal {
        // Any amount send directly to the pool will be assigned pro-rata to all LPs
        weth.deposit{value: amount}();
        weth.transfer(pool, amount);
    }

    function _withdrawFromPool(uint256 amount) internal {
        // The exchange has full control over the pool's funds
        weth.transferFrom(pool, address(this), amount);
        weth.withdraw(amount);
    }

    function _calculatePrice(
        PositionKind positionKind,
        uint256 openInterestLong,
        uint256 openInterestShort,
        uint256 maxExposure,
        uint256 reserve,
        uint256 amount,
        uint256 price
    ) internal view returns (uint256) {
        int256 shift = ((int256(openInterestLong) - int256(openInterestShort)) *
            int256(maxShift)) / int256(maxExposure);

        uint256 slippage;
        if (positionKind == PositionKind.LONG) {
            slippage =
                ((reserve**2 / (reserve - amount) - reserve) * UNIT) /
                amount;
            slippage = shift >= 0
                ? slippage + uint256(shift)
                : slippage - uint256(-1 * shift) / 2;
        } else {
            slippage =
                ((reserve - (reserve**2 / (reserve + amount))) * UNIT) /
                amount;
            slippage = shift >= 0
                ? slippage + uint256(shift) / 2
                : slippage - uint256(-1 * shift);
        }

        return (price * slippage) / UNIT;
    }

    function _updateOpenInterest(
        address nftContractAddress,
        PositionKind positionKind,
        OrderKind orderKind,
        uint256 amount
    ) internal {
        NFTProduct storage nftProduct = nftProducts[nftContractAddress];
        uint256 openInterestLong = nftProduct.openInterestLong;
        uint256 openInterestShort = nftProduct.openInterestShort;
        if (orderKind == OrderKind.OPEN) {
            totalOpenInterest += totalOpenInterest;

            // Make sure the pool is below its maximum utilization
            uint256 poolBalance = Pool(payable(pool)).totalAssets();
            require(
                totalOpenInterest <=
                    (poolBalance * utilizationMultiplier) / BPS,
                "Above maximum open interest"
            );

            // The exposure is the difference between shorts and longs and it
            // basically represents the amount of funds at risk (since shorts
            // and longs will cancel out)
            uint256 maxExposure = (poolBalance *
                nftProduct.maxExposureWeight *
                exposureMultiplier) /
                totalMaxExposureWeight /
                BPS;

            if (positionKind == PositionKind.LONG) {
                openInterestLong += amount;
                require(
                    openInterestLong <= maxExposure + openInterestShort,
                    "Above maximum exposure"
                );
            } else {
                openInterestShort += amount;
                require(
                    openInterestShort <= maxExposure + openInterestLong,
                    "Above maximum exposure"
                );
            }
        } else {
            totalOpenInterest -= amount;
            if (positionKind == PositionKind.LONG) {
                nftProduct.openInterestLong -= (nftProduct.openInterestLong >=
                    amount)
                    ? nftProduct.openInterestLong - amount
                    : 0;
            } else {
                nftProduct.openInterestShort -= (nftProduct.openInterestShort >=
                    amount)
                    ? nftProduct.openInterestShort - amount
                    : 0;
            }
        }
    }

    function getPnL(
        PositionKind positionKind,
        uint256 quotedPrice,
        uint256 positionPrice,
        uint256 size,
        uint256 interest,
        uint256 timestamp
    ) public view returns (int256) {
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
