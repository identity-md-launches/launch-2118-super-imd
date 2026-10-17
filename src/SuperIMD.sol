// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Super IMD (SIMD)
/// @notice A fixed-supply ERC-20 token. The whole supply, 1,000,000,000 SIMD with 18 decimals, is
/// minted once to the deployer in the constructor. Nothing can mint afterwards, there is no owner,
/// no pause, no blocklist, no fee and no hook on transfer: every transfer moves exactly the amount
/// requested.
/// @dev The deployer is `msg.sender` of the constructor. Under the IdentityMD launch that is the
/// ProjectFactory, which pays the whole supply out (swarm distributor, pool seed, remainder). The
/// contract takes no constructor arguments and makes no external call while deploying, so it can be
/// deployed on an empty chain. ERC-2612 `permit` is included so holders can grant allowances with a
/// signature instead of an `approve` transaction.
contract SuperIMD is ERC20, ERC20Permit {
    /// @notice The token's human-readable name, as returned by `name()`.
    string public constant TOKEN_NAME = "Super IMD";

    /// @notice The token's ticker symbol, as returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SIMD";

    /// @notice Number of decimals. The ERC-20 default, restated so the manifest value is in source.
    uint8 public constant TOKEN_DECIMALS = 18;

    /// @notice The fixed total supply in minor units: 1,000,000,000 whole tokens * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(TOKEN_DECIMALS);

    /// @notice Mints the whole fixed supply to the deployer.
    /// @dev Emits a single `Transfer(address(0), msg.sender, TOTAL_SUPPLY)`.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return TOKEN_DECIMALS;
    }
}
