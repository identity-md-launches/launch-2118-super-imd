// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SuperIMD} from "../src/SuperIMD.sol";
import {DeploySuperIMD} from "../script/Deploy.s.sol";

/// @notice Behavioural tests for Super IMD: metadata, the one-time mint, transfers, allowances,
/// permit, and the absence of any privileged power over supply or balances.
/// forge-config: default.fuzz.runs = 1000
contract SuperIMDTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    SuperIMD internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal signerKey;
    address internal signer;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        (signer, signerKey) = makeAddrAndKey("signer");
        vm.prank(deployer);
        token = new SuperIMD();
    }

    // ------------------------------------------------------------------
    // Metadata and constructor
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Super IMD");
        assertEq(token.symbol(), "SIMD");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Super IMD");
        assertEq(token.TOKEN_SYMBOL(), "SIMD");
        assertEq(token.TOKEN_DECIMALS(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.recordLogs();
        vm.prank(alice);
        SuperIMD fresh = new SuperIMD();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "constructor must emit exactly one mint");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_constructorMintsToWhoeverDeploys() public {
        // A contract deployer (the factory in production) receives the supply, not tx.origin.
        Deployer d = new Deployer();
        SuperIMD fresh = d.deploy();
        assertEq(fresh.balanceOf(address(d)), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(address(this)), 0);
        assertEq(fresh.balanceOf(tx.origin), 0);
    }

    function test_deployScriptFunctionDeploysTheToken() public {
        DeploySuperIMD script = new DeploySuperIMD();
        SuperIMD fresh = script.deploy();
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(fresh.name(), "Super IMD");
        assertEq(fresh.symbol(), "SIMD");
    }

    // ------------------------------------------------------------------
    // Transfers
    // ------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 123_456 ether;
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 1 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_transferOfWholeSupplyThenNothingLeft() public {
        vm.prank(deployer);
        token.transfer(alice, EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        token.transfer(alice, 1);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        to = address(uint160(bound(uint256(uint160(to)), 1, type(uint160).max)));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        if (to == deployer) {
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        } else {
            assertEq(token.balanceOf(to), amount);
            assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 attempted) public {
        held = bound(held, 0, EXPECTED_SUPPLY - 1);
        attempted = bound(attempted, held + 1, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempted));
        token.transfer(bob, attempted);
    }

    // ------------------------------------------------------------------
    // Allowances
    // ------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 5 ether);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 5 ether));
        assertEq(token.allowance(deployer, alice), 5 ether);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 4 ether));
        assertEq(token.balanceOf(bob), 4 ether);
        assertEq(token.allowance(deployer, alice), 6 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 4 ether);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 1 ether, 2 ether)
        );
        token.transferFrom(deployer, bob, 2 ether);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function testFuzz_transferFromWithinAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        spent = bound(spent, 0, allowed);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, spent));
        assertEq(token.balanceOf(bob), spent);
        assertEq(token.allowance(deployer, alice), allowed - spent);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ------------------------------------------------------------------
    // ERC-2612 permit
    // ------------------------------------------------------------------

    function _signPermit(uint256 key, address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(key, digest);
    }

    function test_permitGrantsAllowance() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 7 ether, 0, deadline);
        vm.prank(bob); // anyone may relay the signature
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 7 ether);
        assertEq(token.nonces(signer), 1);
    }

    function test_permitCannotBeReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 7 ether, 0, deadline);
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
        vm.expectRevert();
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
    }

    function test_permitRevertsWhenExpired() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(signerKey, signer, alice, 7 ether, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
    }

    function test_permitRevertsForWrongSigner() public {
        (, uint256 otherKey) = makeAddrAndKey("other");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(otherKey, signer, alice, 7 ether, 0, deadline);
        vm.expectRevert();
        token.permit(signer, alice, 7 ether, deadline, v, r, s);
        assertEq(token.allowance(signer, alice), 0);
    }

    function test_domainSeparatorBindsChainAndAddress() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Super IMD")),
                keccak256(bytes("1")),
                block.chainid,
                address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    // ------------------------------------------------------------------
    // No privileged powers
    // ------------------------------------------------------------------

    function test_noMintOrAdminEntryPointExists() public {
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000 ether);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer holds no allowance, so it cannot pull from the holder either.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 1_000 ether);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 500 ether));
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F); // skip PUSH data
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_supportsIERC20Interface() public view {
        IERC20 erc20 = IERC20(address(token));
        assertEq(erc20.totalSupply(), EXPECTED_SUPPLY);
        assertEq(erc20.balanceOf(deployer), EXPECTED_SUPPLY);
    }
}

/// @dev A contract that deploys the token, standing in for the factory: the supply must land on it.
contract Deployer {
    function deploy() external returns (SuperIMD) {
        return new SuperIMD();
    }
}
