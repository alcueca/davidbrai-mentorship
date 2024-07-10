pragma solidity ^0.8.13;

import {console2} from "lib/forge-std/src/console2.sol";
import {CommonBase} from "lib/forge-std/src/Base.sol";
import {StdCheats} from "lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "lib/forge-std/src/StdUtils.sol";

import {ChainlinkPriceFeedMock} from "src/assignment-5/ChainlinkPriceFeedMock.sol";
import {IERC20} from "yield-utils-v2/token/IERC20.sol";

import {CollateralizedVault} from "../../../src/assignment-5/CollateralizedVault.sol";

contract CollateralizedVaultHandler is CommonBase, StdCheats, StdUtils {
    IERC20 public dai;
    IERC20 public weth;
    CollateralizedVault public vault;
    ChainlinkPriceFeedMock public oracle;
    address[] public users;
    mapping(address => bool) public userExists;
    uint256 private randomSeed;

    uint256 public totalDeposits;
    uint256 public totalWithdrawals;

    constructor(IERC20 dai_, IERC20 weth_, CollateralizedVault vault_) {
        dai = dai_;
        weth = weth_;
        vault = vault_;
        oracle = ChainlinkPriceFeedMock(address(vault.oracle()));
    }

    function randomUser(bytes32 seed) public view returns (address) {
        if (users.length == 0)  revert ("No users");
        return users[uint256(keccak256(abi.encodePacked(seed))) % users.length];
    }

    function randomUserWithDebt(bytes32 seed) public view returns (address) {
        uint256 offset = uint256(keccak256(abi.encodePacked(seed))) % users.length;
        for (uint256 i = 0; i < users.length; i++) {
            uint256 userIndex = (offset + i) % users.length;
            if (vault.borrows(users[userIndex]) > 0) {
                return users[i];
            }
        }
        revert ("No user with debt found");
    }

    function firstUnhealthyUser() public view returns (address) {
        for (uint256 i = 0; i < users.length; i++) {
            if (!vault.isHealthy(users[i])) {
                console2.log("Unhealthy!", users[i]);
                return users[i];
            }
        }
        revert ("No unhealthy user found");
    }

    function totalUnhealthyPositions() public view returns (uint256 unhealthyPositions) {
        for (uint256 i = 0; i < users.length; i++) {
            if (!vault.isHealthy(users[i])) {
                console2.log("Unhealthy!", users[i]);
                unhealthyPositions++;
            }
        }
    }

    function totalInsolventPositions() public view returns (uint256 insolventPositions) {
        for (uint256 i = 0; i < users.length; i++) {
            console2.log("Checking...", i, users[i]);
            if (!vault.isSolvent(users[i])) {
                console2.log("Insolvent!", users[i]);
                insolventPositions++;
            }
        }
    }

    function createUnhealthyPosition(uint256 depositAmount) public returns (address user) {
        depositAmount = bound(depositAmount, 1 ether, 1000 ether); // TODO: Consider what to do with very small unhealthy positions
        // TODO: Code reuse for deposit and borrow
        // 1e18 ETH / 500000000000000 DAI/ETH = 2000e18 DAI
        // 1e18 ETH / 400000000000000 DAI/ETH = 2500e18 DAI
        oracle.setPrice(400000000000000); // We can borrow more DAI now
        user = msg.sender;
        if (!userExists[user]) {
            users.push(user);
            userExists[user] = true;
        }
        deal(address(weth), user, depositAmount);

        vm.startPrank(user);
        weth.approve(address(vault), depositAmount);
        vault.deposit(depositAmount);
        totalDeposits += depositAmount;
        uint256 borrowAmount = vault.getMaximumBorrowing(user);
        if (borrowAmount > vault.getMaximumBorrowing())  revert ("Not enough borrowing capacity");
        vault.borrow(borrowAmount);
        vm.stopPrank();

        oracle.setPrice(500000000000000); // Back to normal, the position is now unhealthy
    }

    function deposit(uint256 amount) public payable {
        address user = msg.sender;
        if (!userExists[user]) {
            users.push(user);
            userExists[user] = true;
        }
        amount = bound(amount, 0, 1000 ether);
        deal(address(weth), user, amount);

        vm.startPrank(user);
        weth.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        totalDeposits += amount;
    }
    
    function withdraw(uint256 amount) public {
        address user = randomUser(bytes32(bytes20(msg.sender)));
        amount = bound(amount, 0, vault.deposits(user));

        vm.startPrank(user);
        vault.withdraw(amount);
        vm.stopPrank();

        totalWithdrawals += amount;
    }

    function borrowMax() public {
        address user = randomUser(bytes32(bytes20(msg.sender)));
        uint256 amount = vault.getMaximumBorrowing(vault.deposits(user)) - vault.borrows(user);
        if (amount > vault.getMaximumBorrowing())  revert ("Not enough borrowing capacity");

        vm.startPrank(user);
        vault.borrow(amount);
        vm.stopPrank();
    }

    function borrowPartial(uint256 amount) public {
        address user = randomUser(bytes32(bytes20(msg.sender)));
        amount = bound(amount, 0, vault.getMaximumBorrowing(vault.deposits(user)) - vault.borrows(user));
        if (amount > vault.getMaximumBorrowing())  revert ("Not enough borrowing capacity");

        vm.startPrank(user);
        vault.borrow(amount);
        vm.stopPrank();
    }

    function repayMax() public {
        address user = randomUser(bytes32(bytes20(msg.sender)));
        uint256 amount = vault.borrows(user);
        deal(address(dai), user, amount);

        vm.startPrank(user);
        dai.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();
    }

    function repayPartial(uint256 amount) public {
        address user = randomUser(bytes32(bytes20(msg.sender)));
        amount = bound(amount, 0, vault.borrows(user)); // Repaying all debt will be rarely done
        deal(address(dai), user, amount);

        vm.startPrank(user);
        dai.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();
    }

    function liquidate() public {
        address user = firstUnhealthyUser();

        vm.startPrank(vault.owner());
        totalWithdrawals += vault.deposits(user);
        vault.liquidate(user);
        vm.stopPrank();
    }

    receive() external payable {
    }
}
