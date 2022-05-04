// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20Permit} from "yield-utils-v2/token/ERC20Permit.sol";
import {IERC20} from "yield-utils-v2/token/IERC20.sol";
import {IYearnVault} from "./YearnVaultMock.sol";

/// @title FractionalWrapper is a thin ERC20 wrapper over a Yearn Vault
/// @author davidbrai
/// @notice The wrapper accepts deposits of the underlying token, and in turn,
///     deposits them into the Yearn Vault.
///     The user gets back FractionalWrapper shares which are 1:1 representation of the Yearn Vault shares.
///     The user can burn the shares back into the wrapper, which will burn the Yearn Vault shares, and return
///     the underlying tokens returned from the Yearn Vault.
contract FractionalWrapper is ERC20Permit {

    IERC20 public immutable token;
    IYearnVault public immutable yvToken;

    error TransferFailed();

    /// @notice Initializes a new FractionalWrapper
    /// @param token_ The underlying token
    /// @param yvToken_ The Yearn Vault being wrapped
    /// @param name The name of the wrapper
    /// @param symbol The symbol of the wrapper
    /// @param decimals The number of decimals for the wrapper, should be the same as the Yearn Vault
    constructor(address token_, address yvToken_, string memory name, string memory symbol, uint8 decimals) ERC20Permit(name, symbol, decimals) {
        token = IERC20(token_);
        yvToken = IYearnVault(yvToken_);

        // Allow Yearn Vault to transfer underlying token from the wrapper
        token.approve(yvToken_, type(uint256).max);
    }

    /// @notice Deposit tokens into the contract and gets back wrapper shares which wrap Yearn Vault shares
    ///     1. User sends `amount` of `token` to wrapper
    ///     2. Wrapper sends `amount` of `token` to Yearn Vault
    ///     3. Yearn Vault sends `numShares` of `yvToken` to wrapper
    ///     4. Wrapper sends `numShares` of wrapper shares to user
    /// @param amount The amount of underlying token to deposit
    function deposit(uint amount) public {
        // User sends underlying tokens -> Wrapper
        bool success = token.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert TransferFailed();
        }

        // Wrapper sends underlying tokens -> YVault
        // YVault sends yvTokens to Wrapper
        uint256 numShares = yvToken.deposit(amount);

        // Wrapper sends Wrapper shares to user
        _mint(msg.sender, numShares);
    }

    /// @notice Burns a specified amount of wrapper shares and returns the underlying token to the user
    ///     1. User burns `numShares` of wrapper shares
    ///     2. Wrapper burns `numShares` of `yvToken`
    ///     3. Yearn Vault sends `amount` of `token` to wrapper
    ///     4. Wrapper sends `amount` of `token` back to user
    /// @param numShares The number of wrapper shares to burn
    function burn(uint numShares) public {
        _burn(msg.sender, numShares);

        // Withdraw from YVault, get back underlying token
        uint256 amount = yvToken.withdraw(numShares);

        // Send underlying back to user
        bool success = token.transfer(msg.sender, amount);
        if (!success) {
            revert TransferFailed();
        }
    }
}