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
    using Math for uint256;

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

    /// @dev Collateralization ratio (FP18)
    uint256 public immutable collateralizationRatio;

    /******************
     * State variables
     ******************/

    /// @notice deposited collateral per user in the vault, of `collateral` token
    mapping(address => uint256) public deposits;

    /// @notice Total amount of collateral deposited in the vault, of `collateral` token
    uint256 totalDeposits;

    /// @notice Mapping of current debt per user, of `underlying` token
    mapping(address => uint256) public borrows;

    /// @notice Total amount of debt in the vault, of `underlying` token
    uint256 totalBorrows;

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

    error PositionUnhealthy();

    error PositionHealthy();

    /// @notice Initalizes a new CollateralizedVault
    /// @param underlying_ ERC20 token which can be borrowed from the vault
    /// @param collateral_ ERC20 token which can be used as collateral
    /// @param oracle_ Chainlink price feed of underlying / collateral
    constructor(address underlying_, address collateral_, address oracle_, uint256 collateralizationRatio_) Ownable(msg.sender) {
        underlying = IERC20WithDecimals(underlying_);
        collateral = IERC20WithDecimals(collateral_);
        oracle = AggregatorV3Interface(oracle_);
        collateralizationRatio = collateralizationRatio_;
    }

    /// @notice Deposits additional collateral into the vault
    /// @param collateralAmount amount of `collateral` token to deposit
    function deposit(uint256 collateralAmount) public {
        deposits[msg.sender] += collateralAmount;
        totalDeposits += collateralAmount;

        collateral.transferFrom(msg.sender, address(this), collateralAmount);

        // invariant_NoUnhealthyPositions testing
        // if (collateralAmount % 100 == 99) borrows[msg.sender] = getMaximumBorrowing(collateralAmount) + 1;

        // invariant_NoInsolventPositions testing
        // if (collateralAmount % 100 == 99) borrows[msg.sender] = underlyingValue(collateralAmount) + 1;

        emit Deposit(msg.sender, collateralAmount);
    }

    /// @notice Borrows `underlying` token from the Vault
    ///     Only allowed to borrow up to the value of the collateral
    /// @param amount The amount of `underlying` token to borrow
    function borrow(uint256 amount) public {
        borrows[msg.sender] += amount;
        totalBorrows += amount;

        underlying.transfer(msg.sender, amount);

        if (!isHealthy(msg.sender)) revert PositionUnhealthy();

        emit Borrow(msg.sender, amount);
    }

    /// @notice Pays back an open debt
    /// @param amount The amount of `underlying` token to pay back
    function repay(uint256 amount) public {
        borrows[msg.sender] -= amount;
        totalBorrows -= amount;

        underlying.transferFrom(msg.sender, address(this), amount);

        emit Repay(msg.sender, amount);
    }

    /// @notice Withdraws part of the collateral
    ///     Only allowed to withdraw as long as the collateral left is higher in value than the debt
    /// @param collateralAmount The amount of `collateral` token to withdraw
    function withdraw(uint256 collateralAmount) public {
        deposits[msg.sender] -= collateralAmount;
        totalDeposits -= collateralAmount;

        collateral.transfer(msg.sender, collateralAmount);

        if (!isHealthy(msg.sender)) revert PositionUnhealthy();

        emit Withdraw(msg.sender, collateralAmount);
    }

    /// @notice Return true if a user is healthy
    /// @param user The user to check
    function isHealthy(address user) public view returns (bool) {
        return getMaximumBorrowing(deposits[user]) >= borrows[user];
    }

    /// @notice Return true if a user is solvent
    /// @param user The user to check
    function isSolvent(address user) public view returns (bool) {
        return deposits[user] >= borrows[user].wmulup(getPrice());
    }

    /// @notice Return true if the vault is healthy
    function isHealthy() public view returns (bool) {
        return getMaximumBorrowing(totalDeposits) >= totalBorrows;
    }

    /// @notice Return true if the vault is solvent
    function isSolvent() public view returns (bool) {
        return totalDeposits >= totalBorrows.wmulup(getPrice());
    }

    /// @notice Admin: liquidate a user debt if the collateral value falls below the debt
    /// @param user The user to liquidate
    /// @dev Only admin is allowed to liquidate
    function liquidate(address user) onlyOwner public {
        if (isHealthy(user)) revert PositionHealthy();

        emit Liquidate(user, borrows[user], deposits[user]);

        underlying.transferFrom(msg.sender, address(this), borrows[user]);
        collateral.transfer(owner(), deposits[user]);

        delete borrows[user];
        delete deposits[user];
    }

    /// @notice Returns the required amount of collateral in order to borrow `borrowAmount`
    function getRequiredCollateral(uint256 borrowAmount) public view returns (uint256 requiredCollateral) {
        requiredCollateral = borrowAmount.wmulup(getPrice()).wmulup(collateralizationRatio);
    }

    /// @notice Returns the maximum amount of `underlying` token that can be borrowed with the given collateral
    function getMaximumBorrowing(uint256 collateralAmount) public view returns (uint256 maximumBorrow) {
        maximumBorrow = collateralAmount.wdiv(getPrice()).wdiv(collateralizationRatio);
    }

    function getMaximumBorrowing(address user) public view returns (uint256 maximumBorrow) {
        maximumBorrow = getMaximumBorrowing(deposits[user]) - borrows[user];
    }

    /// @notice Returns the maximum amount of `underlying` token that can be borrowed from the vault
    function getMaximumBorrowing() public view returns (uint256 maximumBorrow) {
        maximumBorrow = underlying.balanceOf(address(this));
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
        return uint256(price);
    }
}

library Math {
    // Taken from https://github.com/usmfum/USM/blob/master/src/WadMath.sol
    /// @dev Multiply an amount by a fixed point factor with 18 decimals, rounds down.
    function wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y;
        unchecked {
            z /= 1e18;
        }
    }

    // Taken from https://github.com/usmfum/USM/blob/master/src/WadMath.sol
    /// @dev Multiply x and y, with y being fixed point. If both are integers, the result is a fixed point factor. Rounds up.
    function wmulup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y + 1e18 - 1; // Rounds up.  So (again imagining 2 decimal places):
        unchecked {
            z /= 1e18;
        } // 383 (3.83) * 235 (2.35) -> 90005 (9.0005), + 99 (0.0099) -> 90104, / 100 -> 901 (9.01).
    }

    // Taken from https://github.com/usmfum/USM/blob/master/src/WadMath.sol
    /// @dev Divide an amount by a fixed point factor with 18 decimals
    function wdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x * 1e18) / y;
    }

    // Taken from https://github.com/usmfum/USM/blob/master/src/WadMath.sol
    /// @dev Divide x and y, with y being fixed point. If both are integers, the result is a fixed point factor. Rounds up.
    function wdivup(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * 1e18 + y; // 101 (1.01) / 1000 (10) -> (101 * 100 + 1000 - 1) / 1000 -> 11 (0.11 = 0.101 rounded up).
        unchecked {
            z -= 1;
        } // Can do unchecked subtraction since division in next line will catch y = 0 case anyway
        z /= y;
    }
}