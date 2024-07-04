// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "yield-utils-v2/token/IERC20.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";

import "forge-std/console2.sol";

interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

/// @title Collateralized Vault
/// @author davidbrai
/// @notice A vault that allows to borrow a token against a collateral
///     If a debt position is not sufficiently collateralized, e.g when the market price
///     of the collateral goes down, then the user's collateral may be liquidated by the admin.
///     In case of a liquidation, both the user's debt and collateral are erased.
/// @dev The Vault uses Chainlink price feeds to determine the value of the collateral compared to the debt
contract CollateralizedVault is Ownable {

    /******************
     * Immutables
     ******************/

    /// @notice ERC20 token which can be borrowed from the vault
    IERC20WithDecimals public immutable underlying;

    /// @notice ERC20 token which can be used as collateral
    IERC20WithDecimals public immutable collateral;

    /// @notice Chainlink priceFeed of underlying / collateral
    ///     e.g. if underlying is DAI and collateral is WETH, priceFeed is for DAI/WETH
    AggregatorV3Interface public immutable oracle;

    /// @dev Number of decimals for underlying token
    uint8 public immutable underlyingDecimals;

    /// @dev Number of decimals for collateral token
    uint8 public immutable collateralDecimals;

    /// @dev Number of decimals for oracle price
    uint8 public immutable oracleDecimals;

    /******************
     * State variables
     ******************/

    /// @notice deposited collateral per user in the vault, of `collateral` token
    mapping(address => uint256) public deposits;

    /// @notice Mapping of current debt per user, of `underlying` token
    mapping(address => uint256) public borrows;

    /******************
     * Events
     ******************/

    /// @notice An event emitted when `user` deposits additional `amount` collateral
    event Deposit(address indexed user, uint256 amount);

    /// @notice An event emitted when `user` borrows `amount` of underlying
    event Borrow(address indexed user, uint256 amount);

    /// @notice An event emitted when `user` repays an `amount` of underlying of their debt
    event Repay(address indexed user, uint256 amount);

    /// @notice An event emitted when `user` withdraws `amount` of their collateral
    event Withdraw(address indexed user, uint256 amount);

    /// @notice An event emitted when `user` is liquidated
    event Liquidate(address indexed user, uint256 debtAmount, uint256 collateralAmount);

    error TooMuchDebt();
    error NotEnoughCollateral();
    error UserDebtIsSufficientlyCollateralized();

    /// @notice Initalizes a new CollateralizedVault
    /// @param underlying_ ERC20 token which can be borrowed from the vault
    /// @param collateral_ ERC20 token which can be used as collateral
    /// @param oracle_ Chainlink price feed of underlying / collateral
    constructor(address underlying_, address collateral_, address oracle_) Ownable(msg.sender) {
        underlying = IERC20WithDecimals(underlying_);
        collateral = IERC20WithDecimals(collateral_);
        oracle = AggregatorV3Interface(oracle_);

        // Gas optimization: save decimals in contract instead of reading from external contract
        underlyingDecimals = underlying.decimals();
        collateralDecimals = collateral.decimals();
        oracleDecimals = oracle.decimals();
    }

    /// @notice Deposits additional collateral into the vault
    /// @param collateralAmount amount of `collateral` token to deposit
    function deposit(uint256 collateralAmount) public {
        deposits[msg.sender] += collateralAmount;

        collateral.transferFrom(msg.sender, address(this), collateralAmount);

        // invariant_NoUnhealthyPositions testing
        // if (collateralAmount % 100 == 99) borrows[msg.sender] = 2000 * collateralAmount + 1;

        emit Deposit(msg.sender, collateralAmount);
    }

    /// @notice Borrows `underlying` token from the Vault
    ///     Only allowed to borrow up to the value of the collateral
    /// @param amount The amount of `underlying` token to borrow
    function borrow(uint256 amount) public {
        if (getRequiredCollateral(borrows[msg.sender] + amount) > deposits[msg.sender]) {
            revert NotEnoughCollateral();
        }

        borrows[msg.sender] += amount;

        underlying.transfer(msg.sender, amount);

        emit Borrow(msg.sender, amount);
    }

    /// @notice Pays back an open debt
    /// @param amount The amount of `underlying` token to pay back
    function repay(uint256 amount) public {
        borrows[msg.sender] -= amount;

        underlying.transferFrom(msg.sender, address(this), amount);

        emit Repay(msg.sender, amount);
    }

    /// @notice Withdraws part of the collateral
    ///     Only allowed to withdraw as long as the collateral left is higher in value than the debt
    /// @param collateralAmount The amount of `collateral` token to withdraw
    function withdraw(uint256 collateralAmount) public {
        uint256 requiredCollateral = getRequiredCollateral(borrows[msg.sender]);

        if (deposits[msg.sender] - collateralAmount < requiredCollateral) {
            revert TooMuchDebt();
        }

        deposits[msg.sender] -= collateralAmount;

        collateral.transfer(msg.sender, collateralAmount);

        emit Withdraw(msg.sender, collateralAmount);
    }

    /// @notice Return true if a user is healthy
    /// @param user The user to check
    function isHealthy(address user) public view returns (bool) {
        return deposits[user] >= getRequiredCollateral(borrows[user]);
    }

    /// @notice Admin: liquidate a user debt if the collateral value falls below the debt
    /// @param user The user to liquidate
    /// @dev Only admin is allowed to liquidate
    function liquidate(address user) onlyOwner public {
        uint256 requiredCollateral = getRequiredCollateral(borrows[user]);
        if (deposits[user] >= requiredCollateral) {
            revert UserDebtIsSufficientlyCollateralized();
        }

        emit Liquidate(user, borrows[user], deposits[user]);

        delete borrows[user];
        delete deposits[user];
    }

    /// @notice Returns the required amount of collateral in order to borrow `borrowAmount`
    function getRequiredCollateral(uint256 borrowAmount) public view returns (uint256 requiredCollateral) {
        requiredCollateral = mulup(borrowAmount, getPrice(), oracleDecimals);
        requiredCollateral = scaleInteger(requiredCollateral, underlyingDecimals, collateralDecimals);
    }

    /// @notice Returns the maximum amount of `underlying` token that can be borrowed with the given collateral
    function getMaximumBorrowing(uint256 collateralAmount) public view returns (uint256 maximumBorrow) {
        maximumBorrow = collateralAmount * 10**oracleDecimals / getPrice();
        maximumBorrow = scaleInteger(maximumBorrow, collateralDecimals, underlyingDecimals);
    }

    /// @dev Scales a fixed point interger from `fromDecimals` to `toDecimals`
    function scaleInteger(uint256 x, uint8 fromDecimals, uint8 toDecimals) public pure returns (uint256) {
        if (toDecimals >= fromDecimals) {
            return x * 10**(toDecimals - fromDecimals);
        } else {
            return x / 10**(fromDecimals - toDecimals);
        }
    }

    /// @notice Returns the price of the underlying token in collateral token units
    function getPrice() public view returns (uint) {
        (
            /*uint80 roundID*/,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = oracle.latestRoundData();
        return toUint256(price);
    }

    function mulup(uint256 x, uint256 y, uint8 decimals) internal pure returns (uint256 z) {
        z = (x * y + 10**decimals - 1) / 10**decimals;
    }

    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "SafeCast: value must be positive");
        return uint256(value);
    }
}