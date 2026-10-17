// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {SIMDPermitSigning} from "./helpers/SIMDPermitSigning.sol";

/// @notice Tracks intended transfers and authorizations independently of token storage. Invalid
/// operations must revert with the expected error; their ghost state remains unchanged.
contract TokenHandler is SIMDPermitSigning {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    SuperIMD public token;
    address[] public actors;
    mapping(address => uint256) private signingKeys;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    mapping(address => uint256) public expectedNonce;

    constructor(SuperIMD token_, address[] memory actors_, uint256[] memory keys_) {
        token = token_;
        actors = actors_;
        assertEq(actors_.length, keys_.length);
        for (uint256 i; i < actors_.length; ++i) {
            assertEq(vm.addr(keys_[i]), actors_[i]);
            signingKeys[actors_[i]] = keys_[i];
        }
        // This is the specified constructor allocation, not a copy of balanceOf.
        expectedBalance[actors_[0]] = SUPPLY;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = _amount(amount, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, _approval(amount));
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 cap = expectedAllowance[owner][spender];
        uint256 bal = expectedBalance[owner];
        amount = _amount(amount, cap < bal ? cap : bal);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        _move(owner, to, amount);
        if (cap != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function permit(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool replay) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = _approval(amount);
        uint256 deadline = block.timestamp;
        Signature memory sig = _sign(token, signingKeys[owner], owner, spender, amount, expectedNonce[owner], deadline);
        token.permit(owner, spender, amount, deadline, sig.v, sig.r, sig.s);
        expectedAllowance[owner][spender] = amount;
        expectedNonce[owner]++;

        if (replay) {
            vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
            token.permit(owner, spender, amount, deadline, sig.v, sig.r, sig.s);
        }
    }

    function rejectTransferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = expectedBalance[from];
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        token.transfer(_actor(toSeed), amount);
    }

    function rejectTransferFromAboveAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 allowed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        allowed = bound(allowed, 0, SUPPLY - 1);
        _approve(owner, spender, allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + 1)
        );
        token.transferFrom(owner, _actor(toSeed), allowed + 1);
    }

    function rejectTransferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 held = expectedBalance[owner];
        amount = bound(amount, held + 1, type(uint256).max);
        _approve(owner, spender, amount);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, _actor(toSeed), amount);
        // transferFrom checks allowance first, so this exercises rollback of an allowance write.
    }

    function rejectZeroReceiver(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool delegated) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        amount = _amount(amount, expectedBalance[owner]);
        if (delegated) {
            _approve(owner, spender, amount);
            vm.prank(spender);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), amount);
        }
    }

    function rejectZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.prank(_actor(ownerSeed));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _move(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _amount(uint256 seed, uint256 cap) private pure returns (uint256) {
        // Explicitly exercise zero, dust and full-balance operations as well as arbitrary amounts.
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return cap == 0 ? 0 : 1;
        if (seed % 4 == 2) return cap;
        return bound(seed, 0, cap);
    }

    function _approval(uint256 seed) private pure returns (uint256) {
        if (seed % 4 == 0) return 0;
        if (seed % 4 == 1) return type(uint256).max;
        if (seed % 4 == 2) return type(uint256).max - 1;
        return bound(seed, 0, SUPPLY);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SuperIMDInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SuperIMD internal token;
    TokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        uint256[] memory keys = new uint256[](6);
        for (uint256 i; i < keys.length; ++i) {
            (address actor, uint256 key) = makeAddrAndKey(string.concat("invariant actor ", vm.toString(i)));
            actors.push(actor);
            keys[i] = key;
        }
        vm.prank(actors[0]);
        token = new SuperIMD();

        handler = new TokenHandler(token, actors, keys);
        // Fund every actor using real transfers. No deal/store cheatcodes bypass token accounting.
        for (uint256 i = 1; i < actors.length; ++i) {
            // A seed congruent to 3 selects the arbitrary-amount branch.
            handler.transfer(0, i, SUPPLY / 6 + 1);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        selectors[3] = TokenHandler.permit.selector;
        selectors[4] = TokenHandler.rejectTransferAboveBalance.selector;
        selectors[5] = TokenHandler.rejectTransferFromAboveAllowance.selector;
        selectors[6] = TokenHandler.rejectTransferFromAboveBalance.selector;
        selectors[7] = TokenHandler.rejectZeroReceiver.selector;
        selectors[8] = TokenHandler.rejectZeroSpender.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_totalSupplyIsConstant() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY);
    }

    function invariant_eachBalanceMatchesAuthorizedTransfers() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]), "incorrect holder balance");
        }
    }

    function invariant_allowancesMatchApprovalsPermitsAndSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "incorrect allowance or failed call did not roll back"
                );
            }
            assertEq(token.allowance(actors[i], address(0)), 0);
        }
    }

    function invariant_onlySuccessfulPermitsConsumeNonces() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.nonces(actors[i]), handler.expectedNonce(actors[i]), "incorrect permit nonce");
        }
    }

    function invariant_zeroAddressNeverHoldsTokens() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    function afterInvariant() public {
        // Every holder must still be able to transfer its entire balance after the random sequence.
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, 2);
            assertEq(token.balanceOf(actors[i]), 0);
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY);
        invariant_totalSupplyIsConstant();
        invariant_eachBalanceMatchesAuthorizedTransfers();
        invariant_allowancesMatchApprovalsPermitsAndSpending();
        invariant_onlySuccessfulPermitsConsumeNonces();
    }
}
