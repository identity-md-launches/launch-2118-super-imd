// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SuperIMD} from "src/SuperIMD.sol";

/// @notice Boundary values, authorization isolation, and atomicity when a transfer fails.
/// forge-config: default.fuzz.runs = 1000
contract SuperIMDEdgeTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    SuperIMD private token;
    address private alice = makeAddr("edge alice");
    address private bob = makeAddr("edge bob");
    address private spender = makeAddr("edge spender");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new SuperIMD();
    }

    function test_oneWeiTransferIsExact() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), alice, 1);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransfersEmitEvenWithoutBalanceOrAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroAmountsDoNotBypassInvalidReceiverOrSpenderChecks() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maxUintTransferRevertsWithoutMovingTokens() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillRequiresSufficientBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(address(this), SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromToOwnerConsumesAllowanceWithoutMovingBalance() public {
        token.approve(spender, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), address(this), SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), SUPPLY));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ownerCallingTransferFromMustApproveItself() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(this), alice, 1);
        token.approve(address(this), 1);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), address(this)), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_maxMinusOneAllowanceIsFinite() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_exhaustedAllowanceCannotBeSpentAgain() public {
        token.approve(spender, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), alice, 1));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_revocationStopsPreviouslyApprovedSpender() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), alice, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(this), alice, 1);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_approvalIsScopedToBothOwnerAndSpender() public {
        token.transfer(alice, 10);
        token.approve(spender, 10);
        vm.prank(bob);
        token.approve(spender, 10);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(address(this), bob, 1);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.allowance(bob, spender), 10);
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 10);
    }

    function testFuzz_approveReplacesRatherThanAdds(uint256 first, uint256 replacement) public {
        token.approve(spender, first);
        token.approve(bob, 7);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, replacement);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(address(this), spender), replacement);
        assertEq(token.allowance(address(this), bob), 7);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.nonces(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientBalanceRollsBackAllowance(uint256 held, uint256 attempted, uint256 allowed) public {
        held = bound(held, 0, SUPPLY);
        attempted = bound(attempted, held + 1, type(uint256).max);
        allowed = bound(allowed, attempted, type(uint256).max);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, allowed);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempted));
        token.transferFrom(alice, bob, attempted);
        assertEq(token.allowance(alice, spender), allowed, "revert must restore allowance spent before balance check");
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientAllowanceLeavesStateUnchanged(uint256 allowed, uint256 attempted) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        attempted = bound(attempted, allowed + 1, SUPPLY);
        token.approve(spender, allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, attempted)
        );
        token.transferFrom(address(this), alice, attempted);
        assertEq(token.allowance(address(this), spender), allowed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_invalidReceiverRollsBackAllowance(uint256 amount, uint256 allowed) public {
        amount = bound(amount, 0, SUPPLY);
        allowed = bound(allowed, amount, type(uint256).max);
        token.approve(spender, allowed);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), amount);
        assertEq(token.allowance(address(this), spender), allowed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_roundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splittingTransferDoesNotChangeAmountReceived(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY / 2);
        first = bound(first, 0, total);
        assertTrue(token.transfer(alice, first));
        assertTrue(token.transfer(alice, total - first));
        assertTrue(token.transfer(bob, total));
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(bob), total);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2 * total);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
