// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";

/// @notice Drives the token with random transfers, approvals and transferFroms among a fixed set of
/// actors so the invariant test can check that the supply is conserved and fully accounted for.
contract TokenHandler is Test {
    SuperIMD public token;
    address[] public actors;

    constructor(SuperIMD token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 cap = token.allowance(owner, spender);
        uint256 bal = token.balanceOf(owner);
        amount = bound(amount, 0, cap < bal ? cap : bal);
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
    }
}

contract SuperIMDInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    SuperIMD internal token;
    TokenHandler internal handler;
    address[] internal actors;

    function setUp() public {
        address deployer = makeAddr("deployer");
        vm.prank(deployer);
        token = new SuperIMD();

        actors.push(deployer);
        for (uint256 i; i < 5; ++i) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        handler = new TokenHandler(token, actors);
        targetContract(address(handler));
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
}
