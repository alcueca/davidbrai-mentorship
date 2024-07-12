// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {CollateralizedVault} from "src/assignment-5/CollateralizedVault.sol";
import {Dai} from "src/assignment-5/DAI.sol";
import {WETH9} from "src/assignment-5/WETH.sol";
import {IERC20} from "yield-utils-v2/token/IERC20.sol";
import {ChainlinkPriceFeedMock} from "src/assignment-5/ChainlinkPriceFeedMock.sol";
import {Ownable} from "openzeppelin/contracts/access/Ownable.sol";

abstract contract ZeroState is Test {

    event Deposit(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Liquidate(address indexed user, uint256 debtAmount, uint256 collateralAmount);

    using stdStorage for StdStorage;

    address USER = address(1);
    CollateralizedVault vault;
    Dai dai;
    WETH9 weth;
    ChainlinkPriceFeedMock priceFeedMock;

    function setUp() public virtual {
        dai = new Dai(block.chainid);
        weth = new WETH9();
        priceFeedMock = new ChainlinkPriceFeedMock();
        priceFeedMock.setPrice(500000000000000); // = 1/2000
        vault = new CollateralizedVault(address(dai), address(weth), address(priceFeedMock), 15e17);

        setDaiBalance(address(vault), 10000 ether);
        setWethBalance(USER, 10 ether);
        vm.prank(USER);
        weth.approve(address(vault), 10 ether);
    }

    function setDaiBalance(address dst, uint256 balance) public {
        stdstore
            .target(address(dai))
            .sig(dai.balanceOf.selector)
            .with_key(dst)
            .depth(0)
            .checked_write(balance);
    }

    function setWethBalance(address dst, uint256 balance) public {
        stdstore
            .target(address(weth))
            .sig(weth.balanceOf.selector)
            .with_key(dst)
            .depth(0)
            .checked_write(balance);
    }
}

contract ZeroStateTest is ZeroState {

    function testGetRequiredCollateral() public {
        priceFeedMock.setPrice(1000000000000000000); // We test the collateralization ratio by itself with this

        assertEq(vault.getRequiredCollateral(1), 2);
        assertEq(vault.getRequiredCollateral(4000), 6000);
        assertEq(vault.getRequiredCollateral(4000 ether), 6000 ether);

        priceFeedMock.setPrice(500000000000000);

        assertEq(vault.getRequiredCollateral(1), 2);
        assertEq(vault.getRequiredCollateral(4000), 3);
        assertEq(vault.getRequiredCollateral(4000 ether), 3 ether);

        priceFeedMock.setPrice(250000000000000); // Half the price, half the required collateral

        assertEq(vault.getRequiredCollateral(1), 2);
        assertEq(vault.getRequiredCollateral(4000), 2);
        assertEq(vault.getRequiredCollateral(4000 ether), 1.5 ether);
    }

    function testGetMaximumBorrowing() public {
        priceFeedMock.setPrice(1000000000000000000); // We test the collateralization ratio by itself with this
        
        assertEq(vault.getMaximumBorrowing(2), 1);
        assertEq(vault.getMaximumBorrowing(3000), 2000);
        assertEq(vault.getMaximumBorrowing(3 ether), 2 ether);

        priceFeedMock.setPrice(500000000000000);

        assertEq(vault.getMaximumBorrowing(1), 1333);
        assertEq(vault.getMaximumBorrowing(3), 4000);
        assertEq(vault.getMaximumBorrowing(3 ether), 4000 ether);

        priceFeedMock.setPrice(1000000000000000); // Double the price, half the maximum borrowing

        assertEq(vault.getMaximumBorrowing(1), 666);
        assertEq(vault.getMaximumBorrowing(3), 2000);
        assertEq(vault.getMaximumBorrowing(3 ether), 2000 ether);
    }

    function testDeposit() public {
        vm.prank(USER);
        vm.expectEmit(true, true, true, true);
        emit Deposit(USER, 3 ether);
        vault.deposit(3 ether);

        // 3 WETH was transfered to the vault
        assertEq(weth.balanceOf(USER), 7 ether);
        assertEq(weth.balanceOf(address(vault)), 3 ether);

        // User collateral is recorded
        assertEq(vault.deposits(USER), 3 ether);
    }

    function testDepositMultipleTimesAccumulatesCollateral() public {
        vm.startPrank(USER);

        vault.deposit(1 ether);
        vault.deposit(1 ether);

        assertEq(weth.balanceOf(address(vault)), 2 ether);
        assertEq(vault.deposits(USER), 2 ether);
    }
}

abstract contract DepositedCollateralState is ZeroState {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(USER);
        vault.deposit(3 ether);

        vm.prank(USER);
        dai.approve(address(vault), type(uint256).max);
    }
}

contract DepositedCollateralStateTest is DepositedCollateralState {
    function testBorrow() public {
        vm.prank(USER);
        vm.expectEmit(true, true, true, true);
        emit Borrow(USER, 4000 * 1e18);
        vault.borrow(4000 * 1e18);

        // 4000 DAI was transfered to the USER
        assertEqDecimal(dai.balanceOf(USER), 4000 * 1e18, 18);

        // User debt is recorded
        assertEq(vault.borrows(USER), 4000 * 1e18);
    }

    function testBorrowMultipleTimesAccumulatesDebt() public {
        vm.startPrank(USER);

        vault.borrow(5 * 1e18);
        vault.borrow(10 * 1e18);

        assertEqDecimal(dai.balanceOf(USER), 15 * 1e18, 18);
        assertEq(vault.borrows(USER), 15 * 1e18);
    }

    function testRevertsWhenTryingToBorrowTooMuch() public {
        vm.prank(USER);
        vm.expectRevert(CollateralizedVault.PositionUnhealthy.selector);
        vault.borrow(4000 * 1e18 + 1);
    }
}

abstract contract BorrowedState is DepositedCollateralState {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(USER);
        vault.borrow(4000 ether);
    }
}

contract BorrowedStateTest is BorrowedState {

    function testIsHealthy() public {
        assertTrue(vault.isHealthy(USER));
    }

    function testIsNotHealthy() public {
        priceFeedMock.setPrice(600000000000000);
        assertFalse(vault.isHealthy(USER));
    }

    function testRepayDebt() public {
        vm.prank(USER);
        vm.expectEmit(true, true, true, true);
        emit Repay(USER, 2000 ether);
        vault.repay(2000 ether);

        assertEq(vault.borrows(USER), 2000 ether);
        assertEq(dai.balanceOf(USER), 2000 ether);
    }

    function testRepayTooMuchDebtReverts() public {
        vm.prank(USER);
        vm.expectRevert(stdError.arithmeticError);
        vault.repay(6001 ether);
    }

    function testCantWithdrawCollateral() public {
        vm.prank(USER);
        vm.expectRevert(CollateralizedVault.PositionUnhealthy.selector);
        vault.withdraw(1);
    }

    function testCanWithdrawEntireCollateralIfPaidAllDebt() public {
        assertEq(weth.balanceOf(USER), 7 ether);
        assertEq(vault.borrows(USER), 4000 ether);
        assertEq(vault.deposits(USER), 3 ether);

        // Repay entire debt
        vm.startPrank(USER);
        vault.repay(4000 ether);
        // No more debt
        assertEq(vault.borrows(USER), 0);
        // But also no more DAI
        assertEq(dai.balanceOf(USER), 0);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(USER, 3 ether);
        vault.withdraw(3 ether);
        // WETH is returned to user
        assertEq(weth.balanceOf(USER), 10 ether);
    }

    // TODO: FIX
    // function testOnlyOwnerCanLiquidate() public {
    //     vm.prank(address(0x1234));
    //     vm.expectRevert(Ownable.OwnableUnauthorizedAccount.selector);
    //     vault.liquidate(USER);
    // }

    function testOwnerCantLiquidateIfDebtIsCollateralized() public {
        vm.expectRevert(CollateralizedVault.PositionHealthy.selector);
        vault.liquidate(USER);
    }

    function testOwnerCanLiquidateIfDebtIsUnderCollateralized() public {
        // WETH went down, now only $1000, DAI/ETH = 1/1000
        priceFeedMock.setPrice(1000000000000000);

        // Need 6 WETH
        assertEq(vault.getRequiredCollateral(vault.borrows(USER)), 6 ether);
        // But only 3 is deposited
        assertEq(vault.deposits(USER), 3 ether);

        // liquidate user
        deal(address(dai), address(this), 4000 ether); // Produce the dai to repay the debt
        dai.approve(address(vault), 4000 ether);
        vm.expectEmit(true, true, true, true);
        emit Liquidate(USER, 4000 ether, 3 ether);
        vault.liquidate(USER);

        assertEq(vault.deposits(USER), 0);
        assertEq(vault.borrows(USER), 0);
    }
}

abstract contract PartiallyRepaidDebtState is BorrowedState {
    function setUp() virtual override public {
        super.setUp();

        // Repay 2 thirds of debt
        vm.prank(USER);
        vault.repay(2000 ether);
    }
}

contract PartiallyRepaidDebtStateTest is PartiallyRepaidDebtState {

    function testWithdrawPartialCollateral() public {
        // 1 third debt left
        assertEq(vault.borrows(USER), 2000 ether);

        vm.prank(USER);
        vault.withdraw(1.5 ether);
        // WETH is returned to user
        assertEq(weth.balanceOf(USER), 8.5 ether);
    }

    function testRevertWhenTryingToWithdrawTooMuch() public {
        vm.prank(USER);
        vm.expectRevert(CollateralizedVault.PositionUnhealthy.selector);
        vault.withdraw(2 ether + 1);
    }

    function testCanWithdrawLessIfPriceMovedNegatively() public {
        priceFeedMock.setPrice(900000000000000);

        // can't withdraw 1.5 WETH
        vm.prank(USER);
        vm.expectRevert(CollateralizedVault.PositionUnhealthy.selector);
        vault.withdraw(1.5 ether);

        // but 0.3 WETH is OK
        vm.prank(USER);
        vault.withdraw(0.3 ether);
    }

    function testCanWithdrawMoreIfPriceMovePositively() public {
        priceFeedMock.setPrice(200000000000000);

        vm.prank(USER);
        vault.withdraw(2.4 ether);
    }
}