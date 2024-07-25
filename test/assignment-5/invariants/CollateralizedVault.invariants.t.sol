// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CollateralizedVaultHandler} from "./CollateralizedVaultHandler.sol";

import {CollateralizedVault} from "src/assignment-5/CollateralizedVault.sol";
import {Dai} from "src/assignment-5/DAI.sol";
import {WETH9} from "src/assignment-5/WETH.sol";
import {IERC20} from "yield-utils-v2/token/IERC20.sol";
import {ChainlinkPriceFeedMock} from "src/assignment-5/ChainlinkPriceFeedMock.sol";

abstract contract ZeroState is StdInvariant, Test {

    event Deposit(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Liquidate(address indexed user, uint256 debtAmount, uint256 collateralAmount);

    using stdStorage for StdStorage;

    uint256 public constant INITIAL_UNDERLYING_BALANCE = 256 * 1000000 ether;
    int256 public constant INITIAL_PRICE = 500000000000000; // = 1/2000

    address USER = address(1);
    CollateralizedVault vault;
    IERC20 dai;
    IERC20 weth;
    ChainlinkPriceFeedMock priceFeedMock;

    CollateralizedVaultHandler handler;

    function setUp() public virtual {
        dai = IERC20(address(new Dai(block.chainid)));
        weth = IERC20(address(new WETH9()));
        priceFeedMock = new ChainlinkPriceFeedMock();
        priceFeedMock.setPrice(INITIAL_PRICE);
        vault = new CollateralizedVault(address(dai), address(weth), address(priceFeedMock), 15e17);

        deal(address(dai), address(vault), INITIAL_UNDERLYING_BALANCE);

        handler = new CollateralizedVaultHandler(dai, weth, vault);
        targetContract(address(handler));
       // targetContract(address(weth));
       // targetContract(address(dai));

        excludeSender(address(priceFeedMock));
        excludeSender(address(vault));
        excludeSender(address(weth));
        excludeSender(address(dai));
    }
}

contract ZeroStateTest is ZeroState {

    /// @dev Sum of deposits == contract collateral balance
    function invariant_CollateralPreservation() public view {
        assertLe(handler.totalDeposits() - handler.totalWithdrawals(), weth.balanceOf(address(vault)));
    }

    /// @dev Sum of borrows + contract balance == initial underlying balance
    function invariant_UnderlyingPreservation() public view {
        assertLe(INITIAL_UNDERLYING_BALANCE + handler.totalRepayments() - handler.totalBorrows(), dai.balanceOf(address(vault)));
    }

    /// @dev No price change, single block, no way for positions to become unhealthy
    /// This will fail if the handler is allowed to create unhealthy positions, doh!
    // function invariant_NoUnhealthyPositions() public view {
    //     assertEq(handler.totalUnhealthyPositions(), 0);
    // }

    /// @dev No price change, no way for protocol to become insolvent
    /// Needs a collateralization ratio above 1 to be different from invariant_NoUnhealthyPositions
    function invariant_NoInsolventPositions() public view {
        assertEq(handler.totalInsolventPositions(), 0);
    }

    /// @dev No insolvent positions, solvent position gets liquidated, protocol is solvent
    function invariant_OvercollateralizedProtocol() public view {
        // assertEq(handler.totalInsolventPositions(), 0); // This is guaranteed in the previous test
        assertEq(vault.isSolvent(), true);
    }

    /// @dev Collateral can always be withdrawn down to the healthy position level
    function invariant_WithdrawalDownToHealthy() public view {
        assertFalse(handler.failedWithdrawMax());
    }

    function testFuzzDeposit(uint256 amount) public {
        handler.deposit(amount);
    }

    function testFuzzCreateUnhealthyPosition(uint256 amount) public {
        amount = bound(amount, 0, 1000 ether);
        handler.createUnhealthyPosition(amount);
        assertEq(handler.totalUnhealthyPositions(), 1);
    }
}

abstract contract DepositedCollateralState is ZeroState {
    function setUp() public virtual override {
        super.setUp();

        handler.deposit(100 ether);
    }
}

contract DepositedCollateralStateTest is DepositedCollateralState {
    
    function testFuzzDepositAgain(uint256 amount) public {
        handler.depositAgain(amount);
    }

    function testFuzzWithdraw(uint256 amount) public {
        handler.withdraw(amount);
    }

    function testFuzzBorrowMax() public {
        handler.borrowMax();
    }

    function testFuzzBorrowPartial(uint256 amount) public {
        handler.borrowPartial(amount);
    }
}

abstract contract BorrowedState is DepositedCollateralState {
    function setUp() public virtual override {
        super.setUp();

        handler.borrowPartial(50 ether);
        handler.createUnhealthyPosition(50 ether); // We also need unhealthy positions for testing repay and liquidation
    }
}

contract BorrowedStateTest is BorrowedState {
    function testFuzzRepayMax() public {
        handler.repayMax();
    }

    function testFuzzRepayPartial(uint256 amount) public {
        handler.repayPartial(amount);
    }

    function testFuzzLiquidate(uint256 amount) public {
        handler.liquidate(amount);
    }
}
