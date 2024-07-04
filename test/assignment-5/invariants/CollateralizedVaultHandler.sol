pragma solidity ^0.8.13;

import {console2} from "lib/forge-std/src/console2.sol";
import {CommonBase} from "lib/forge-std/src/Base.sol";
import {StdCheats} from "lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "lib/forge-std/src/StdUtils.sol";

import {IERC20} from "yield-utils-v2/token/IERC20.sol";
import {CollateralizedVault} from "../../../src/assignment-5/CollateralizedVault.sol";

contract CollateralizedVaultHandler is CommonBase, StdCheats, StdUtils {
    IERC20 public dai;
    IERC20 public weth;
    CollateralizedVault public vault;
    address[] public users;
    mapping(address => bool) public userExists;
    uint256 private randomSeed;

    uint256 public totalDeposits;
    uint256 public totalWithdrawals;

    constructor(IERC20 dai_, IERC20 weth_, CollateralizedVault vault_) {
        dai = dai_;
        weth = weth_;
        vault = vault_;
    }

    function randomUser(bytes32 seed) public view returns (address) {
        return users[uint256(keccak256(abi.encodePacked(seed))) % users.length];
    }

    function totalUnhealthyPositions() public view returns (uint256 unhealthyPositions) {
        for (uint256 i = 0; i < users.length; i++) {
            console2.log("Checking...", i, users[i]);
            if (!vault.isHealthy(users[i])) {
                console2.log("Unhealthy!", users[i]);
                unhealthyPositions++;
            }
        }
    }

    function deposit(uint256 amount) public payable {
        address user = msg.sender;
        if(user.codehash == 0) { // Instead of a blanket ban on contracts, we should have a whitelist
            if (!userExists[user]) {
                users.push(user);
                userExists[user] = true;
            }
            amount = bound(amount, 0, 1000 ether);
            deal(address(weth), address(this), amount);
            weth.transfer(user, amount);

            vm.startPrank(user);
            weth.approve(address(vault), amount);
            vault.deposit(amount);
            vm.stopPrank();

            totalDeposits += amount;
        }
    }

    function withdraw(uint256 amount) public {
        address user = randomUser(bytes32(bytes20(msg.sender)));
        amount = bound(amount, 0, vault.deposits(user));

        vm.startPrank(user);
        vault.withdraw(amount);
        vm.stopPrank();

        totalWithdrawals += amount;
    }
//
//    function sendFallback(uint256 amount) public {
//        amount = bound(amount, 0, address(this).balance);
//        depositors.push(msg.sender);
//        msg.sender.call{value: amount}("");
//        vm.prank(msg.sender);
//        address(weth).call{value: amount}("");
//        totalDeposits += amount;
//    }

    receive() external payable {
    }
}
