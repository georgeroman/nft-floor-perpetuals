// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/SignedSafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../oracle/IOracle.sol";
import "../lib/UniERC20.sol";
import "../lib/PerpLib.sol";
import "./IPikaPerp.sol";
import "../staking/IVaultReward.sol";

contract PikaPerpV2 is ReentrancyGuard {
    using SafeMath for uint256;
    using SignedSafeMath for int256;
    using SafeERC20 for IERC20;
    using UniERC20 for IERC20;
    // All amounts are stored with 8 decimals

    // Structs

    struct Vault {
        // 32 bytes
        uint96 cap; // Maximum capacity. 12 bytes
        uint96 balance; // 12 bytes
        uint64 staked; // Total staked by users. 8 bytes
        uint64 shares; // Total ownership shares. 8 bytes
        // 32 bytes
        uint32 stakingPeriod; // Time required to lock stake (seconds). 4 bytes
    }

    struct Stake {
        // 32 bytes
        address owner; // 20 bytes
        uint64 amount; // 8 bytes
        uint64 shares; // 8 bytes
        uint32 timestamp; // 4 bytes
    }

    struct Product {
        // 32 bytes
        address productToken; // 20 bytes
        uint72 maxLeverage; // 9 bytes
        uint16 fee; // In bps. 0.5% = 50. 2 bytes
        bool isActive; // 1 byte
        // 32 bytes
        uint64 openInterestLong; // 6 bytes
        uint64 openInterestShort; // 6 bytes
        uint16 interest; // For 360 days, in bps. 10% = 1000. 2 bytes
        uint16 liquidationThreshold; // In bps. 8000 = 80%. 2 bytes
        uint16 liquidationBounty; // In bps. 500 = 5%. 2 bytes
        uint16 minPriceChange; // 1.5%, the minimum oracle price up change for trader to close trade with profit
        uint16 weight; // share of the max exposure
        uint64 reserve; // Virtual reserve in USDC. Used to calculate slippage
    }

    struct Position {
        // 32 bytes
        uint64 productId; // 8 bytes
        uint64 leverage; // 8 bytes
        uint64 price; // 8 bytes
        uint64 oraclePrice; // 8 bytes
        uint64 margin; // 8 bytes
        // 32 bytes
        address owner; // 20 bytes
        uint80 timestamp; // 10 bytes
        uint80 averageTimestamp; // 10 bytes
        bool isLong; // 1 byte
    }

    // Variables

    address public owner;
    address public liquidator;
    address public token;
    uint256 public tokenBase;
    address public oracle;
    uint256 public minMargin;
    uint256 public protocolRewardRatio = 2000; // 20%
    uint256 public pikaRewardRatio = 3000; // 30%
    uint256 public maxShift = 0.003e8; // max shift (shift is used adjust the price to balance the longs and shorts)
    uint256 public minProfitTime = 6 hours; // the time window where minProfit is effective
    uint256 public maxPositionMargin; // for guarded launch
    uint256 public totalWeight; // total exposure weights of all product
    uint256 public exposureMultiplier = 10000; // exposure multiplier
    uint256 public utilizationMultiplier = 10000; // exposure multiplier
    uint256 public pendingProtocolReward; // protocol reward collected
    uint256 public pendingPikaReward; // pika reward collected
    uint256 public pendingVaultReward; // vault reward collected
    address public protocolRewardDistributor;
    address public pikaRewardDistributor;
    address public vaultRewardDistributor;
    address public vaultTokenReward;
    address public feeCalculator;
    uint256 public totalOpenInterest;
    uint256 public constant BASE = 10**8;
    bool canUserStake = false;
    bool allowPublicLiquidator = false;
    bool isTradeEnabled = true;
    Vault private vault;

    mapping(uint256 => Product) private products;
    mapping(address => Stake) private stakes;
    mapping(uint256 => Position) private positions;
    mapping(address => bool) public liquidators;
    mapping(address => bool) public managers;
    mapping(address => mapping(address => bool)) public approvedManagers;
    // Events

    event Staked(address indexed user, uint256 amount, uint256 shares);
    event Redeemed(
        address indexed user,
        address indexed receiver,
        uint256 amount,
        uint256 shares,
        uint256 shareBalance,
        bool isFullRedeem
    );
    event NewPosition(
        uint256 indexed positionId,
        address indexed user,
        uint256 indexed productId,
        bool isLong,
        uint256 price,
        uint256 oraclePrice,
        uint256 margin,
        uint256 leverage,
        uint256 fee
    );

    event AddMargin(
        uint256 indexed positionId,
        address indexed sender,
        address indexed user,
        uint256 margin,
        uint256 newMargin,
        uint256 newLeverage
    );
    event ClosePosition(
        uint256 indexed positionId,
        address indexed user,
        uint256 indexed productId,
        uint256 price,
        uint256 entryPrice,
        uint256 margin,
        uint256 leverage,
        uint256 fee,
        int256 pnl,
        bool wasLiquidated
    );
    event PositionLiquidated(
        uint256 indexed positionId,
        address indexed liquidator,
        uint256 liquidatorReward,
        uint256 remainingReward
    );
    event ProtocolRewardDistributed(address to, uint256 amount);
    event PikaRewardDistributed(address to, uint256 amount);
    event VaultRewardDistributed(address to, uint256 amount);
    event VaultUpdated(Vault vault);
    event ProductAdded(uint256 productId, Product product);
    event ProductUpdated(uint256 productId, Product product);
    event OwnerUpdated(address newOwner);

    // Constructor

    constructor(
        address _token,
        uint256 _tokenBase,
        address _oracle,
        address _feeCalculator
    ) {
        owner = msg.sender;
        liquidator = msg.sender;
        token = _token;
        tokenBase = _tokenBase;
        oracle = _oracle;
        feeCalculator = _feeCalculator;
    }

    // Methods

    function stake(uint256 amount, address user) external payable nonReentrant {
        require(canUserStake || msg.sender == owner, "!stake");
        require(msg.sender == user || _validateManager(user), "!stake");
        IVaultReward(vaultRewardDistributor).updateReward(user);
        IVaultReward(vaultTokenReward).updateReward(user);
        IERC20(token).uniTransferFromSenderToThis(
            amount.mul(tokenBase).div(BASE)
        );
        require(uint256(vault.staked) + amount <= uint256(vault.cap), "!cap");
        uint256 shares = vault.staked > 0
            ? amount.mul(uint256(vault.shares)).div(uint256(vault.balance))
            : amount;
        vault.balance += uint96(amount);
        vault.staked += uint64(amount);
        vault.shares += uint64(shares);

        if (stakes[user].amount == 0) {
            stakes[user] = Stake({
                owner: user,
                amount: uint64(amount),
                shares: uint64(shares),
                timestamp: uint32(block.timestamp)
            });
        } else {
            stakes[user].amount += uint64(amount);
            stakes[user].shares += uint64(shares);
            stakes[user].timestamp = uint32(block.timestamp);
        }

        emit Staked(user, amount, shares);
    }

    function redeem(
        address user,
        uint256 shares,
        address receiver
    ) external {
        require(shares <= uint256(vault.shares), "!staked");

        require(user == msg.sender || _validateManager(user), "!redeemed");
        IVaultReward(vaultRewardDistributor).updateReward(user);
        IVaultReward(vaultTokenReward).updateReward(user);
        Stake storage _stake = stakes[user];
        bool isFullRedeem = shares >= uint256(_stake.shares);
        if (isFullRedeem) {
            shares = uint256(_stake.shares);
        }

        uint256 timeDiff = block.timestamp.sub(uint256(_stake.timestamp));
        require(timeDiff > uint256(vault.stakingPeriod), "!period");

        uint256 shareBalance = shares.mul(uint256(vault.balance)).div(
            uint256(vault.shares)
        );

        uint256 amount = shares.mul(_stake.amount).div(uint256(_stake.shares));

        _stake.amount -= uint64(amount);
        _stake.shares -= uint64(shares);
        vault.staked -= uint64(amount);
        vault.shares -= uint64(shares);
        vault.balance -= uint96(shareBalance);

        require(
            totalOpenInterest <=
                uint256(vault.balance).mul(utilizationMultiplier).div(10**4),
            "!utilized"
        );

        if (isFullRedeem) {
            delete stakes[user];
        }
        IERC20(token).uniTransfer(
            receiver,
            shareBalance.mul(tokenBase).div(BASE)
        );

        emit Redeemed(
            user,
            receiver,
            amount,
            shares,
            shareBalance,
            isFullRedeem
        );
    }

    function openPosition(
        address user,
        uint256 productId,
        uint256 margin,
        bool isLong,
        uint256 leverage
    ) public payable nonReentrant returns (uint256 positionId) {
        require(user == msg.sender || _validateManager(user), "not-allowed");
        require(isTradeEnabled, "not-enabled");
        // Check params
        require(margin >= minMargin, "!margin");
        require(leverage >= 1 * BASE, "!leverage");

        // Check product
        Product storage product = products[productId];
        require(product.isActive, "!product-active");
        require(leverage <= uint256(product.maxLeverage), "!max-leverage");

        // Transfer margin plus fee
        uint256 tradeFee = PerpLib._getTradeFee(
            margin,
            leverage,
            uint256(product.fee),
            product.productToken,
            user,
            feeCalculator
        );
        IERC20(token).uniTransferFromSenderToThis(
            (margin.add(tradeFee)).mul(tokenBase).div(BASE)
        );
        pendingProtocolReward = pendingProtocolReward.add(
            tradeFee.mul(protocolRewardRatio).div(10**4)
        );
        pendingPikaReward = pendingPikaReward.add(
            tradeFee.mul(pikaRewardRatio).div(10**4)
        );
        pendingVaultReward = pendingVaultReward.add(
            tradeFee.mul(10**4 - protocolRewardRatio - pikaRewardRatio).div(
                10**4
            )
        );

        uint256 amount = margin.mul(leverage).div(BASE);
        uint256 price = _calculatePrice(
            product.productToken,
            PositionKind.LONG,
            product.openInterestLong,
            product.openInterestShort,
            uint256(vault.balance)
                .mul(uint256(product.weight))
                .mul(exposureMultiplier)
                .div(uint256(totalWeight))
                .div(10**4),
            uint256(product.reserve),
            amount
        );

        _updateOpenInterest(
            nftContractAddress,
            PositionKind.LONG,
            OrderKind.OPEN,
            amount
        );

        positionId = getPositionId(user, productId, isLong);
        Position storage position = positions[positionId];
        if (position.margin > 0) {
            price = (
                uint256(position.margin)
                    .mul(position.leverage)
                    .mul(uint256(position.price))
                    .add(margin.mul(leverage).mul(price))
            ).div(
                    uint256(position.margin).mul(position.leverage).add(
                        margin.mul(leverage)
                    )
                );
            leverage = (
                uint256(position.margin).mul(uint256(position.leverage)).add(
                    margin.mul(leverage)
                )
            ).div(uint256(position.margin).add(margin));
            margin = uint256(position.margin).add(margin);
        }
        require(margin < maxPositionMargin, "!max margin");

        positions[positionId] = Position({
            owner: user,
            productId: uint64(productId),
            margin: uint64(margin),
            leverage: uint64(leverage),
            price: uint64(price),
            oraclePrice: uint64(IOracle(oracle).getPrice(product.productToken)),
            timestamp: uint80(block.timestamp),
            averageTimestamp: position.margin == 0
                ? uint80(block.timestamp)
                : uint80(
                    (
                        uint256(position.margin)
                            .mul(uint256(position.timestamp))
                            .add(margin.mul(block.timestamp))
                    ).div(uint256(position.margin).add(margin))
                ),
            isLong: isLong
        });
        emit NewPosition(
            positionId,
            user,
            productId,
            isLong,
            price,
            IOracle(oracle).getPrice(product.productToken),
            margin,
            leverage,
            tradeFee
        );
    }

    // Add margin to Position with positionId
    function addMargin(uint256 positionId, uint256 margin)
        external
        payable
        nonReentrant
    {
        IERC20(token).uniTransferFromSenderToThis(
            margin.mul(tokenBase).div(BASE)
        );

        // Check params
        require(margin >= minMargin, "!margin");

        // Check position
        Position storage position = positions[positionId];
        require(
            msg.sender == position.owner || _validateManager(position.owner),
            "not-allowed"
        );

        // New position params
        uint256 newMargin = uint256(position.margin).add(margin);
        uint256 newLeverage = uint256(position.leverage)
            .mul(uint256(position.margin))
            .div(newMargin);
        require(newLeverage >= 1 * BASE, "!low-leverage");

        position.margin = uint64(newMargin);
        position.leverage = uint64(newLeverage);

        emit AddMargin(
            positionId,
            msg.sender,
            position.owner,
            margin,
            newMargin,
            newLeverage
        );
    }

    function closePosition(
        address user,
        uint256 productId,
        uint256 margin,
        bool isLong
    ) external {
        return
            closePositionWithId(getPositionId(user, productId, isLong), margin);
    }

    // Closes position from Position with id = positionId
    function closePositionWithId(uint256 positionId, uint256 margin)
        public
        nonReentrant
    {
        // Check position
        Position storage position = positions[positionId];
        require(
            msg.sender == position.owner || _validateManager(position.owner),
            "!closePosition"
        );

        // Check product
        Product storage product = products[uint256(position.productId)];

        bool isFullClose;
        if (margin >= uint256(position.margin)) {
            margin = uint256(position.margin);
            isFullClose = true;
        }
        uint256 maxExposure = uint256(vault.balance)
            .mul(uint256(product.weight))
            .mul(exposureMultiplier)
            .div(uint256(totalWeight))
            .div(10**4);
        uint256 price = _calculatePrice(
            product.productToken,
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
                    uint256(position.oraclePrice),
                    IOracle(oracle).getPrice(product.productToken),
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

    function _updateVaultAndGetFee(
        int256 pnl,
        Position memory position,
        uint256 margin,
        uint256 fee,
        uint256 interest,
        address productToken
    ) private returns (uint256) {
        (int256 pnlAfterFee, uint256 totalFee) = _getPnlWithFee(
            pnl,
            position,
            margin,
            fee,
            interest,
            productToken
        );
        // Update vault
        if (pnlAfterFee < 0) {
            uint256 _pnlAfterFee = uint256(-1 * pnlAfterFee);
            if (_pnlAfterFee < margin) {
                IERC20(token).uniTransfer(
                    position.owner,
                    (margin.sub(_pnlAfterFee)).mul(tokenBase).div(BASE)
                );
                vault.balance += uint96(_pnlAfterFee);
            } else {
                vault.balance += uint96(margin);
                return totalFee;
            }
        } else {
            uint256 _pnlAfterFee = uint256(pnlAfterFee);
            // Check vault
            require(
                uint256(vault.balance) >= _pnlAfterFee,
                "!vault-insufficient"
            );
            vault.balance -= uint96(_pnlAfterFee);

            IERC20(token).uniTransfer(
                position.owner,
                (margin.add(_pnlAfterFee)).mul(tokenBase).div(BASE)
            );
        }

        pendingProtocolReward = pendingProtocolReward.add(
            totalFee.mul(protocolRewardRatio).div(10**4)
        );
        pendingPikaReward = pendingPikaReward.add(
            totalFee.mul(pikaRewardRatio).div(10**4)
        );
        pendingVaultReward = pendingVaultReward.add(
            totalFee.mul(10**4 - protocolRewardRatio - pikaRewardRatio).div(
                10**4
            )
        );
        vault.balance -= uint96(totalFee);

        return totalFee;
    }

    // Liquidate positionIds
    function liquidatePositions(uint256[] calldata positionIds) external {
        require(
            liquidators[msg.sender] || allowPublicLiquidator,
            "!liquidator"
        );

        uint256 totalLiquidatorReward;
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 positionId = positionIds[i];
            uint256 liquidatorReward = liquidatePosition(positionId);
            totalLiquidatorReward = totalLiquidatorReward.add(liquidatorReward);
        }
        if (totalLiquidatorReward > 0) {
            IERC20(token).uniTransfer(
                msg.sender,
                totalLiquidatorReward.mul(tokenBase).div(BASE)
            );
        }
    }

    function liquidatePosition(uint256 positionId)
        private
        returns (uint256 liquidatorReward)
    {
        Position storage position = positions[positionId];
        if (position.productId == 0) {
            return 0;
        }
        Product storage product = products[uint256(position.productId)];
        uint256 price = IOracle(oracle).getPrice(product.productToken); // use oracle price for liquidation

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
                pendingPikaReward = pendingPikaReward.add(
                    remainingReward.mul(pikaRewardRatio).div(10**4)
                );
                pendingVaultReward = pendingVaultReward.add(
                    remainingReward
                        .mul(10**4 - protocolRewardRatio - pikaRewardRatio)
                        .div(10**4)
                );
                vault.balance += uint96(_pnl);
            } else {
                vault.balance += uint96(position.margin);
            }

            uint256 amount = uint256(position.margin)
                .mul(uint256(position.leverage))
                .div(BASE);

            _updateOpenInterest(
                uint256(position.productId),
                amount,
                position.isLong,
                false
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

    function _updateOpenInterest(
        uint256 productId,
        uint256 amount,
        bool isLong,
        bool isIncrease
    ) private {
        Product storage product = products[productId];
        if (isIncrease) {
            totalOpenInterest = totalOpenInterest.add(amount);
            require(
                totalOpenInterest <=
                    uint256(vault.balance).mul(utilizationMultiplier).div(
                        10**4
                    ),
                "!maxOpenInterest"
            );
            uint256 maxExposure = uint256(vault.balance)
                .mul(uint256(product.weight))
                .mul(exposureMultiplier)
                .div(uint256(totalWeight))
                .div(10**4);
            if (isLong) {
                product.openInterestLong += uint64(amount);
                require(
                    uint256(product.openInterestLong) <=
                        uint256(maxExposure).add(
                            uint256(product.openInterestShort)
                        ),
                    "!exposure-long"
                );
            } else {
                product.openInterestShort += uint64(amount);
                require(
                    uint256(product.openInterestShort) <=
                        uint256(maxExposure).add(
                            uint256(product.openInterestLong)
                        ),
                    "!exposure-short"
                );
            }
        } else {
            totalOpenInterest = totalOpenInterest.sub(amount);
            if (isLong) {
                if (uint256(product.openInterestLong) >= amount) {
                    product.openInterestLong -= uint64(amount);
                } else {
                    product.openInterestLong = 0;
                }
            } else {
                if (uint256(product.openInterestShort) >= amount) {
                    product.openInterestShort -= uint64(amount);
                } else {
                    product.openInterestShort = 0;
                }
            }
        }
    }

    function _validateManager(address account) private returns (bool) {
        require(managers[msg.sender], "!manager");
        require(approvedManagers[account][msg.sender], "!approvedManager");
        return true;
    }

    function distributeProtocolReward() external returns (uint256) {
        require(msg.sender == protocolRewardDistributor, "!distributor");
        uint256 _pendingProtocolReward = pendingProtocolReward
            .mul(tokenBase)
            .div(BASE);
        if (pendingProtocolReward > 0) {
            pendingProtocolReward = 0;
            IERC20(token).uniTransfer(
                protocolRewardDistributor,
                _pendingProtocolReward
            );
            emit ProtocolRewardDistributed(
                protocolRewardDistributor,
                _pendingProtocolReward
            );
        }
        return _pendingProtocolReward;
    }

    function distributePikaReward() external returns (uint256) {
        require(msg.sender == pikaRewardDistributor, "!distributor");
        uint256 _pendingPikaReward = pendingPikaReward.mul(tokenBase).div(BASE);
        if (pendingPikaReward > 0) {
            pendingPikaReward = 0;
            IERC20(token).uniTransfer(
                pikaRewardDistributor,
                _pendingPikaReward
            );
            emit PikaRewardDistributed(
                pikaRewardDistributor,
                _pendingPikaReward
            );
        }
        return _pendingPikaReward;
    }

    function distributeVaultReward() external returns (uint256) {
        require(msg.sender == vaultRewardDistributor, "!distributor");
        uint256 _pendingVaultReward = pendingVaultReward.mul(tokenBase).div(
            BASE
        );
        if (pendingVaultReward > 0) {
            pendingVaultReward = 0;
            IERC20(token).uniTransfer(
                vaultRewardDistributor,
                _pendingVaultReward
            );
            emit VaultRewardDistributed(
                vaultRewardDistributor,
                _pendingVaultReward
            );
        }
        return _pendingVaultReward;
    }

    // Getters

    function getPendingPikaReward() external view returns (uint256) {
        return pendingPikaReward.mul(tokenBase).div(BASE);
    }

    function getPendingProtocolReward() external view returns (uint256) {
        return pendingProtocolReward.mul(tokenBase).div(BASE);
    }

    function getPendingVaultReward() external view returns (uint256) {
        return pendingVaultReward.mul(tokenBase).div(BASE);
    }

    function getVault() external view returns (Vault memory) {
        return vault;
    }

    function getProduct(uint256 productId)
        external
        view
        returns (
            address,
            uint256,
            uint256,
            bool,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        Product memory product = products[productId];
        return (
            product.productToken,
            uint256(product.maxLeverage),
            uint256(product.fee),
            product.isActive,
            uint256(product.openInterestLong),
            uint256(product.openInterestShort),
            uint256(product.interest),
            uint256(product.liquidationThreshold),
            uint256(product.liquidationBounty),
            uint256(product.minPriceChange),
            uint256(product.weight),
            uint256(product.reserve)
        );
    }

    function getPositionId(
        address account,
        uint256 productId,
        bool isLong
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(account, productId, isLong)));
    }

    function getPosition(
        address account,
        uint256 productId,
        bool isLong
    )
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            address,
            uint256,
            uint256,
            bool
        )
    {
        Position memory position = positions[
            getPositionId(account, productId, isLong)
        ];
        return (
            uint256(position.productId),
            uint256(position.leverage),
            uint256(position.price),
            uint256(position.oraclePrice),
            uint256(position.margin),
            position.owner,
            uint256(position.timestamp),
            uint256(position.averageTimestamp),
            position.isLong
        );
    }

    function getPositions(uint256[] calldata positionIds)
        external
        view
        returns (Position[] memory _positions)
    {
        uint256 length = positionIds.length;
        _positions = new Position[](length);
        for (uint256 i = 0; i < length; i++) {
            _positions[i] = positions[positionIds[i]];
        }
    }

    function getTotalShare() external view returns (uint256) {
        return uint256(vault.shares);
    }

    function getShare(address stakeOwner) external view returns (uint256) {
        return uint256(stakes[stakeOwner].shares);
    }

    function getShareBalance(address stakeOwner)
        external
        view
        returns (uint256)
    {
        if (vault.shares == 0) {
            return 0;
        }
        return
            (uint256(stakes[stakeOwner].shares))
                .mul(uint256(vault.balance))
                .div(uint256(vault.shares));
    }

    function getStake(address stakeOwner) external view returns (Stake memory) {
        return stakes[stakeOwner];
    }

    // Internal methods

    function _calculatePrice(
        address productToken,
        bool isLong,
        uint256 openInterestLong,
        uint256 openInterestShort,
        uint256 maxExposure,
        uint256 reserve,
        uint256 amount
    ) private view returns (uint256) {
        uint256 oraclePrice = IOracle(oracle).getPrice(productToken);
        int256 shift = ((int256(openInterestLong) - int256(openInterestShort)) *
            int256(maxShift)) / int256(maxExposure);
        if (isLong) {
            uint256 slippage = (
                reserve.mul(reserve).div(reserve.sub(amount)).sub(reserve)
            ).mul(BASE).div(amount);
            slippage = shift >= 0
                ? slippage.add(uint256(shift))
                : slippage.sub(uint256(-1 * shift).div(2));
            return oraclePrice.mul(slippage).div(BASE);
        } else {
            uint256 slippage = (
                reserve.sub(reserve.mul(reserve).div(reserve.add(amount)))
            ).mul(BASE).div(amount);
            slippage = shift >= 0
                ? slippage.add(uint256(shift).div(2))
                : slippage.sub(uint256(-1 * shift));
            return oraclePrice.mul(slippage).div(BASE);
        }
    }

    function _getPnlWithFee(
        int256 pnl,
        Position memory position,
        uint256 margin,
        uint256 fee,
        uint256 interest,
        address productToken
    ) private view returns (int256 pnlAfterFee, uint256 totalFee) {
        // Subtract trade fee from P/L
        uint256 tradeFee = PerpLib._getTradeFee(
            margin,
            uint256(position.leverage),
            fee,
            productToken,
            position.owner,
            feeCalculator
        );
        pnlAfterFee = pnl.sub(int256(tradeFee));

        // Subtract interest from P/L
        uint256 interestFee = margin
            .mul(uint256(position.leverage))
            .mul(interest)
            .mul(block.timestamp.sub(uint256(position.averageTimestamp)))
            .div(uint256(10**12).mul(365 days));
        pnlAfterFee = pnlAfterFee.sub(int256(interestFee));
        totalFee = tradeFee.add(interestFee);
    }

    // Owner methods

    function updateVault(Vault memory _vault) external onlyOwner {
        require(
            _vault.cap > 0 &&
                _vault.stakingPeriod > 0 &&
                _vault.stakingPeriod < 30 days,
            "not-allowed"
        );

        vault.cap = _vault.cap;
        vault.stakingPeriod = _vault.stakingPeriod;

        emit VaultUpdated(vault);
    }

    function addProduct(uint256 productId, Product memory _product)
        external
        onlyOwner
    {
        require(productId > 0, "!productId");
        Product memory product = products[productId];
        require(product.maxLeverage == 0, "!product-exists");

        require(_product.maxLeverage > 1 * BASE, "!max-leverage");
        require(_product.productToken != address(0), "!productToken");
        require(_product.liquidationThreshold > 0, "!liquidationThreshold");

        products[productId] = Product({
            productToken: _product.productToken,
            maxLeverage: _product.maxLeverage,
            fee: _product.fee,
            isActive: true,
            openInterestLong: 0,
            openInterestShort: 0,
            interest: _product.interest,
            liquidationThreshold: _product.liquidationThreshold,
            liquidationBounty: _product.liquidationBounty,
            minPriceChange: _product.minPriceChange,
            weight: _product.weight,
            reserve: _product.reserve
        });
        totalWeight += _product.weight;

        emit ProductAdded(productId, products[productId]);
    }

    function updateProduct(uint256 productId, Product memory _product)
        external
        onlyOwner
    {
        require(productId > 0, "!productId");
        Product storage product = products[productId];
        require(product.maxLeverage > 0, "!product-exists");

        require(_product.maxLeverage >= 1 * BASE, "!max-leverage");
        require(_product.productToken != address(0), "!productToken");
        require(_product.liquidationThreshold > 0, "!liquidationThreshold");

        product.productToken = _product.productToken;
        product.maxLeverage = _product.maxLeverage;
        product.fee = _product.fee;
        product.isActive = _product.isActive;
        product.interest = _product.interest;
        product.liquidationThreshold = _product.liquidationThreshold;
        product.liquidationBounty = _product.liquidationBounty;
        totalWeight = totalWeight - product.weight + _product.weight;
        product.weight = _product.weight;

        emit ProductUpdated(productId, product);
    }

    function setDistributors(
        address _protocolRewardDistributor,
        address _pikaRewardDistributor,
        address _vaultRewardDistributor,
        address _vaultTokenReward
    ) external onlyOwner {
        protocolRewardDistributor = _protocolRewardDistributor;
        pikaRewardDistributor = _pikaRewardDistributor;
        vaultRewardDistributor = _vaultRewardDistributor;
        vaultTokenReward = _vaultTokenReward;
    }

    function setManager(address _manager, bool _isActive) external onlyOwner {
        managers[_manager] = _isActive;
    }

    function setAccountManager(address _manager, bool _isActive) external {
        approvedManagers[msg.sender][_manager] = _isActive;
    }

    function setRewardRatio(
        uint256 _protocolRewardRatio,
        uint256 _pikaRewardRatio
    ) external onlyOwner {
        require(_protocolRewardRatio + _pikaRewardRatio <= 10000, "!too-much");
        protocolRewardRatio = _protocolRewardRatio;
        pikaRewardRatio = _pikaRewardRatio;
    }

    function setMargin(uint256 _minMargin, uint256 _maxPositionMargin)
        external
        onlyOwner
    {
        minMargin = _minMargin;
        maxPositionMargin = _maxPositionMargin;
    }

    function setTradeEnabled(bool _isTradeEnabled) external {
        require(msg.sender == owner || managers[msg.sender], "!not-allowed");
        isTradeEnabled = _isTradeEnabled;
    }

    function setParameters(
        uint256 _maxShift,
        uint256 _minProfitTime,
        bool _canUserStake,
        bool _allowPublicLiquidator,
        uint256 _exposureMultiplier,
        uint256 _utilizationMultiplier
    ) external onlyOwner {
        require(_maxShift <= 0.01e8 && _minProfitTime <= 24 hours);
        maxShift = _maxShift;
        minProfitTime = _minProfitTime;
        canUserStake = _canUserStake;
        allowPublicLiquidator = _allowPublicLiquidator;
        exposureMultiplier = _exposureMultiplier;
        utilizationMultiplier = _utilizationMultiplier;
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
    }

    function setFeeCalculator(address _feeCalculator) external onlyOwner {
        feeCalculator = _feeCalculator;
    }

    function setLiquidator(address _liquidator, bool _isActive)
        external
        onlyOwner
    {
        liquidators[_liquidator] = _isActive;
    }

    function setOwner(address _owner) external onlyOwner {
        owner = _owner;
        emit OwnerUpdated(_owner);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "!owner");
        _;
    }
}
