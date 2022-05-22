// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {TrustusPacket} from "./interfaces/trustus/TrustusPacket.sol";
import {PerpLib} from "./PerpLib.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";

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
        // the minimum oracle price up change for trader to close trade with profit
        uint16 minPriceChange; 
    }

    // Each user can have at most two active positions on any particular NFT
    // (a long position and/or a short position). The id of any position can
    // be computed via `keccak256(user, nft, kind)`.
    struct Position {
        address owner;
        uint256 margin;
        uint256 leverage;
        uint256 timestamp;
        uint256 price;
        uint256 oraclePrice;
        bool isLong;
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

    // The time window where minProfit is effective
    uint256 public minProfitTime = 6 hours; 

    // Trusted address of the oracle responsible for pricing and settling new orders
    address public oracle;

    // Address of the pool that handles liquidity provision
    address public pool;

    // allow anyone to liquidate
    bool allowPublicLiquidator = false;

    // payment token for liquidators
    address public token;

    // tokenBase
    uint256 public tokenBase;

    // token BASE
    uint256 public constant BASE = 10**8;

    // protocol reward collected
    uint256 public pendingProtocolReward;

    // pika token collected
    uint256 public pendingTokenReward; 
    
    // pool reward collected
    uint256 public pendingPoolReward; 

    // 30%
    uint256 public tokenRewardRatio = 3000;  

    uint256 public protocolRewardRatio = 2000;  // 20%
    
    // total exposure weights of all product
    uint256 public totalWeight; 

    address public feeCalculator;

    // Mapping from NFT contract address to tradeable NFT product details
    mapping(address => NFTProduct) public nftProducts;

    // Indexed by position id
    mapping(bytes32 => Position) public positions;

    // allowed addresses that can call liquidations
    mapping(address => bool) public liquidators;

    // --- Events ---

    event NFTProductAdded(address nftContractAddress);
    event NFTProductRemoved(address nftContractAddress);

    event Log(address);

    event ClosePosition(
        bytes32 positionId,
        address positionOwner,
        uint256 price,
        uint256 positionPrice,
        uint256 positionMargin,
        uint256 positionLeverage,
        uint256 fee,
        int256 pnl,
        bool wasLiquidated
    );

    event PositionLiquidated(
        bytes32 positionId,
        address caller,
        uint256 liquidatorReward,
        uint256 remainingReward
    );

    // --- Constructor ---

    constructor(address ownerAddress, address oracleAddress, address _token, uint256 _tokenBase, address _feeCalculator)
        Owned(ownerAddress)
    {
        oracle = oracleAddress;
        pool = address(new Pool(address(this)));
        token = _token;
        tokenBase = _tokenBase;
        feeCalculator = _feeCalculator;
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
                        nftContractAddress
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
        emit Log(signer);
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
            owner: msg.sender,
            margin: margin,
            leverage: leverage,
            price: price,
            oraclePrice: IOracle(oracle).getPrice(nftContractAddress),
            timestamp: timestamp,
            isLong: positionKind == PositionKind.LONG
        });

        // TODO: Emit event
    }

    // NOT FINISHED
    function liquidatePositions(uint256[] calldata positionIds, address[] calldata nftAddresses) external {
        require(
            liquidators[msg.sender] || allowPublicLiquidator,
            "!liquidator"
        );

        require(positionIds.length == nftAddresses.length, "Parameter arrays length must be equal");

        uint256 totalLiquidatorReward;
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            uint256 liquidatorReward = liquidatePosition(positionId, nftAddresses[i]);
            totalLiquidatorReward = totalLiquidatorReward + liquidatorReward;
        }
        if (totalLiquidatorReward > 0) {
            IERC20(token).uniTransfer(
                msg.sender,
                totalLiquidatorReward * (tokenBase/BASE)
            );
        }
    }

    // ---- Private ----

    function _updateVaultAndGetFee(
        int256 pnl,
        Position memory position,
        uint256 margin,
        uint256 fee,
        uint256 interest,
        address productToken
    ) private returns(uint256) {

        (int256 pnlAfterFee, uint256 totalFee) = _getPnlWithFee(pnl, position, margin, fee, interest, productToken);
        // Update vault
        if (pnlAfterFee < 0) {
            uint256 _pnlAfterFee = uint256(-1 * pnlAfterFee);
            if (_pnlAfterFee < margin) {
                IERC20(token).uniTransfer(position.owner, (margin.sub(_pnlAfterFee)).mul(tokenBase).div(BASE));
                IERC20(token).transferFrom(msg.sender, address(this), _pnlAfterFee);
            } else {
                IERC20(token).transferFrom(msg.sender, address(this), margin);
                return totalFee;
            }

        } else {
            uint256 _pnlAfterFee = uint256(pnlAfterFee);
            // Check vault
            require(uint256(IERC20(token).balanceOf(address(this))) >= _pnlAfterFee, "!vault-insufficient");
            IERC20(token).transferFrom(msg.sender, address(this), _pnlAfterFee);

            IERC20(token).uniTransfer(position.owner, (margin.add(_pnlAfterFee)).mul(tokenBase).div(BASE));
        }

        pendingProtocolReward = pendingProtocolReward.add(totalFee.mul(protocolRewardRatio).div(10**4));
        pendingTokenReward = pendingTokenReward.add(totalFee.mul(tokenRewardRatio).div(10**4));
        pendingPoolReward = pendingPoolReward.add(totalFee.mul(10**4 - protocolRewardRatio - tokenRewardRatio).div(10**4));
        IERC20(token).transferFrom(msg.sender, address(this), totalFee);

        return totalFee;
    }

    function _getPnlWithFee(
        int256 pnl,
        Position memory position,
        uint256 margin,
        uint256 fee,
        uint256 interest,
        address productToken
    ) private view returns(int256 pnlAfterFee, uint256 totalFee) {
        // Subtract trade fee from P/L
        uint256 tradeFee = PerpLib._getTradeFee(margin, uint256(position.leverage), fee, productToken, position.owner, feeCalculator);
        pnlAfterFee = pnl.sub(int256(tradeFee));

        // Subtract interest from P/L
        uint256 interestFee = margin.mul(uint256(position.leverage)).mul(interest)
            .mul(block.timestamp.sub(uint256(position.averageTimestamp))).div(uint256(10**12).mul(365 days));
        pnlAfterFee = pnlAfterFee.sub(int256(interestFee));
        totalFee = tradeFee.add(interestFee);
    }

    // NOT FINISHED
    function liquidatePosition(uint256 positionId, address nftAddress)
        private
        returns (uint256 liquidatorReward)
    {
        Position storage position = positions[positionId];
        // if (position.productId == 0) {
        //     return 0;
        // }
        NFTProduct storage product = nftProducts[nftAddress];
        uint256 price = IOracle(oracle).getPrice(nftAddress); // use oracle price for liquidation

        uint256 remainingReward;
        if (
            PerpLib._checkLiquidation(
                position.isLong,
                position.price,
                position.leverage,
                price,
                uint256(product.liquidationThreshold)
            )
        ) {
            int256 pnl = PerpLib._getPnl(
                position.isLong,
                position.price,
                position.leverage,
                position.margin,
                price
            );
            if (pnl < 0 && uint256(position.margin) > uint256(-1 * pnl)) {
                uint256 _pnl = uint256(-1 * pnl);
                liquidatorReward = (uint256(position.margin).sub(_pnl))
                    .mul(uint256(product.liquidationBounty))
                    .div(10**4);
                remainingReward = (
                    uint256(position.margin).sub(_pnl).sub(liquidatorReward)
                );
                pendingProtocolReward = pendingProtocolReward.add(
                    remainingReward.mul(protocolRewardRatio).div(10**4)
                );
                pendingTokenReward = pendingTokenReward.add(
                    remainingReward.mul(tokenRewardRatio).div(10**4)
                );
                pendingPoolReward = pendingPoolReward.add(
                    remainingReward
                        .mul(10**4 - protocolRewardRatio - tokenRewardRatio)
                        .div(10**4)
                );
                IERC20(token).transferFrom(msg.sender, address(this), uint96(_pnl));
            } else {
                IERC20(token).transferFrom(msg.sender, address(this), uint96(position.margin));
            }

            uint256 amount = uint256(position.margin)
                .mul(uint256(position.leverage))
                .div(BASE);

            PositionKind positionKind = PositionKind.LONG;

            if (!position.isLong) {
                positionKind = PositionKind.SHORT;
            }

            _updateOpenInterest(
                nftAddress,
                positionKind,
                OrderKind.CLOSE,
                amount
            );

            emit ClosePosition(
                positionId,
                position.owner,
                uint256(position.productId),
                price,
                uint256(position.price),
                uint256(position.margin),
                uint256(position.leverage),
                0,
                -1 * int256(uint256(position.margin)),
                true
            );

            delete positions[positionId];

            emit PositionLiquidated(
                positionId,
                msg.sender,
                liquidatorReward,
                remainingReward
            );
        }
        return liquidatorReward;
    }

    function closePosition(
        address user,
        address nftContractAddress,
        PositionKind positionKind,
        uint256 margin
    ) external {
        return
            closePositionWithId(getPositionId(user, nftContractAddress, positionKind), margin, nftContractAddress);
    }

    // Closes position from Position with id = positionId
    function closePositionWithId(bytes32 positionId, uint256 margin, address nftContractAddress)
        public
    {
        // Check position
        Position storage position = positions[positionId];
        require(msg.sender == position.owner, "!closePosition");

        // Check product
        NFTProduct storage product = nftProducts[nftContractAddress];

        bool isFullClose;
        if (margin >= uint256(position.margin)) {
            margin = uint256(position.margin);
            isFullClose = true;
        }
        uint256 maxExposure = uint256(IERC20(token).balanceOf(address(this)))
            .mul(uint256(product.weight))
            .mul(exposureMultiplier)
            .div(uint256(totalWeight))
            .div(10**4);
        uint256 price = _calculatePrice(
            nftContractAddress,
            !position.isLong,
            product.openInterestLong,
            product.openInterestShort,
            maxExposure,
            uint256(product.reserve),
            (margin * position.leverage) / BASE
        );

        bool isLiquidatable;
        int256 pnl = PerpLib._getPnl(
            position.isLong,
            uint256(position.price),
            uint256(position.leverage),
            margin,
            price
        );
        if (
            pnl < 0 &&
            uint256(-1 * pnl) >=
            margin.mul(uint256(product.liquidationThreshold)).div(10**4)
        ) {
            margin = uint256(position.margin);
            pnl = -1 * int256(uint256(position.margin));
            isLiquidatable = true;
        } else {
            // front running protection: if oracle price up change is smaller than threshold and minProfitTime has not passed, the pnl is be set to 0
            if (
                pnl > 0 &&
                !PerpLib._canTakeProfit(
                    position.isLong,
                    uint256(position.timestamp),
                    position.oraclePrice,
                    IOracle(oracle).getPrice(nftContractAddress),
                    product.minPriceChange,
                    minProfitTime
                )
            ) {
                pnl = 0;
            }
        }

        uint256 totalFee = _updateVaultAndGetFee(
            pnl,
            position,
            margin,
            uint256(product.fee),
            uint256(product.interest),
            product.productToken
        );
        _updateOpenInterest(
            uint256(position.productId),
            margin.mul(uint256(position.leverage)).div(BASE),
            position.isLong,
            false
        );

        emit ClosePosition(
            positionId,
            position.owner,
            uint256(position.productId),
            price,
            uint256(position.price),
            margin,
            uint256(position.leverage),
            totalFee,
            pnl,
            isLiquidatable
        );

        if (isFullClose) {
            delete positions[positionId];
        } else {
            position.margin -= uint64(margin);
        }
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
        product.minPriceChange = 0;

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
