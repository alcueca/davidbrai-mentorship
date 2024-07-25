pragma solidity ^0.8.13;

import {console2} from "lib/forge-std/src/console2.sol";
import {CommonBase} from "lib/forge-std/src/Base.sol";
import {StdCheats} from "lib/forge-std/src/StdCheats.sol";
import {StdUtils} from "lib/forge-std/src/StdUtils.sol";

import {ChainlinkPriceFeedMock} from "src/assignment-5/ChainlinkPriceFeedMock.sol";
import {IERC20} from "yield-utils-v2/token/IERC20.sol";

import {CollateralizedVault} from "../../../src/assignment-5/CollateralizedVault.sol";

contract CollateralizedVaultHandler is CommonBase, StdCheats, StdUtils {
    uint256 public constant MAX_DEPOSIT = 1000 ether;

    IERC20 public dai;
    IERC20 public weth;
    CollateralizedVault public vault;
    ChainlinkPriceFeedMock public oracle;
    address[] public users;
    mapping(address => bool) public userExists;
    uint256 private randomSeed;

    uint256 public totalDeposits;
    uint256 public totalWithdrawals;
    uint256 public totalBorrows;
    uint256 public totalRepayments;
    bool public failedWithdrawMax;
    bool public unhealthyUserIncreasedDebt;

    constructor(IERC20 dai_, IERC20 weth_, CollateralizedVault vault_) {
        dai = dai_;
        weth = weth_;
        vault = vault_;
        oracle = ChainlinkPriceFeedMock(address(vault.oracle()));
    }

    modifier unhealthyUsersDoNotIncreaseDebt(address user) {
        bool isHealthy = vault.isHealthy(user);
        uint256 debtBefore = vault.borrows(user);
        _;
        if (!isHealthy) unhealthyUserIncreasedDebt = vault.borrows(user) > debtBefore;
    }

    function randomUserIndex(bytes32 seed) public view returns (uint256) {
        if (users.length == 0)  revert ("No users");
        return uint256(keccak256(abi.encodePacked(seed))) % users.length;
    }

    function randomUser(bytes32 seed) public view returns (address) {
        return users[randomUserIndex(seed)];
    }

    function randomHealthyUser(bytes32 seed) public view returns (address) {
        uint256 offset = randomUserIndex(seed);
        for (uint256 i = 0; i < users.length; i++) {
            uint256 userIndex = (offset + i) % users.length;
            if (vault.isHealthy(users[userIndex])) {
                return users[i];
            }
        }
        revert ("No healthy user found");
    }

    function randomUnhealthyUser(bytes32 seed) public view returns (address) {
        uint256 offset = randomUserIndex(seed);
        for (uint256 i = 0; i < users.length; i++) {
            uint256 userIndex = (offset + i) % users.length;
            if (!vault.isHealthy(users[userIndex])) {
                return users[i];
            }
        }
        revert ("No unhealthy user found");
    }

    function randomUserWithDebt(bytes32 seed) public view returns (address) {
        uint256 offset = randomUserIndex(seed);
        for (uint256 i = 0; i < users.length; i++) {
            uint256 userIndex = (offset + i) % users.length;
            if (vault.borrows(users[userIndex]) > 0) {
                return users[i];
            }
        }
        revert ("No user with debt found");
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

    function _deposit(address user, uint256 amount) private unhealthyUsersDoNotIncreaseDebt(user) {
        deal(address(weth), user, amount);

        vm.startPrank(user);
        weth.approve(address(vault), amount);
        vault.deposit(amount);
        vm.stopPrank();

        totalDeposits += amount;
    }

    function _withdraw(address user, uint256 amount) private unhealthyUsersDoNotIncreaseDebt(user) {
        vm.startPrank(user);
        vault.withdraw(amount);
        vm.stopPrank();

        totalWithdrawals += amount;
    }

    function _borrow(address user, uint256 amount) private unhealthyUsersDoNotIncreaseDebt(user) {
        vm.startPrank(user);
        vault.borrow(amount);
        vm.stopPrank();

        totalBorrows += amount;
    }

    function _repay(address user, uint256 amount) private unhealthyUsersDoNotIncreaseDebt(user) {
        deal(address(dai), user, amount);

        vm.startPrank(user);
        dai.approve(address(vault), amount);
        vault.repay(amount);
        vm.stopPrank();

        totalRepayments += amount;
    }

    function _liquidate(address user) private {
        uint256 depositAmount = vault.deposits(user);
        uint256 borrowAmount = vault.borrows(user);

        totalWithdrawals += depositAmount;
        totalRepayments += borrowAmount;

        vm.startPrank(vault.owner());
        deal(address(dai), vault.owner(), borrowAmount);
        dai.approve(address(vault), borrowAmount);
        vault.liquidate(user);
        vm.stopPrank();
    }

    function _createUnhealthyPosition(uint256 depositAmount) private returns (address user) {
        depositAmount = bound(depositAmount, 1 ether, MAX_DEPOSIT); // TODO: Consider what to do with very small unhealthy positions
        // 1e18 ETH / 500000000000000 DAI/ETH = 2000e18 DAI
        // 1e18 ETH / 400000000000000 DAI/ETH = 2500e18 DAI
        oracle.setPrice(400000000000000); // We can borrow more DAI now
        user = msg.sender;
        if (!userExists[user]) {
            users.push(user);
            userExists[user] = true;
        }
        _deposit(user, depositAmount);

        uint256 borrowAmount = vault.getMaximumBorrowing(user) - vault.borrows(user);
        if (borrowAmount > vault.getMaximumBorrowing())  revert ("Not enough borrowing capacity");
        _borrow(user, borrowAmount);

        oracle.setPrice(500000000000000); // Back to normal, the position is now unhealthy
    }

    function createUnhealthyPosition(uint256 depositAmount) public {
        _createUnhealthyPosition(depositAmount);
    }

    function deposit(uint256 amount) public payable {
        address user = msg.sender;
        if (!userExists[user]) {
            users.push(user);
            userExists[user] = true;
        }
        amount = bound(amount, 0, MAX_DEPOSIT);
        _deposit(user, amount);
    }
    
    function depositAgain(uint256 amount) public payable {
        address user = randomUser(bytes20(msg.sender));
        amount = bound(amount, 0, 1000 ether);
        _deposit(user, amount);
    }

    function withdraw(uint256 amount) public {
        address user = randomUser(bytes20(msg.sender));
        amount = bound(amount, 0, vault.deposits(user));
        _withdraw(user, amount);
    }

    function withdrawMax() public {
        address user = randomHealthyUser(bytes20(msg.sender)); // It's expected that unlheathy users can't withdraw
        uint256 amount = vault.deposits(user) - vault.getRequiredCollateral(vault.borrows(user));

        vm.startPrank(user);
        try vault.withdraw(amount) {
            totalWithdrawals += amount;
        }
        catch {
            failedWithdrawMax = true;
        }
        vm.stopPrank();
    }

    function borrowMax() public {
        address user = randomUser(bytes20(msg.sender));
        uint256 amount = vault.getMaximumBorrowing(vault.deposits(user)) - vault.borrows(user);
        if (amount > vault.getMaximumBorrowing())  revert ("Not enough borrowing capacity");
        _borrow(user, amount);
    }

    function borrowPartial(uint256 amount) public {
        address user = randomUser(bytes20(msg.sender));
        amount = bound(amount, 0, vault.getMaximumBorrowing(vault.deposits(user)) - vault.borrows(user));
        if (amount > vault.getMaximumBorrowing())  revert ("Not enough borrowing capacity");
        _borrow(user, amount);
    }

    function repayMax() public {
        address user = randomUserWithDebt(bytes20(msg.sender));
        uint256 amount = vault.borrows(user);
        _repay(user, amount);
    }

    function repayPartial(uint256 amount) public {
        address user = randomUserWithDebt(bytes20(msg.sender));
        amount = bound(amount, 0, vault.borrows(user)); // Repaying all debt will be rarely done
        _repay(user, amount);
    }

    function liquidate(uint256 randomAmount) public {
        address user = _createUnhealthyPosition(randomAmount);
        _liquidate(user);
    }

    receive() external payable {
    }
}
