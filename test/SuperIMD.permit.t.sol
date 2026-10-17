// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SuperIMD} from "src/SuperIMD.sol";
import {SIMDPermitSigning} from "./helpers/SIMDPermitSigning.sol";

/// @notice Permit is an implemented authorization path: invalid signatures must never consume
/// a nonce or alter an existing allowance, and valid signatures must authorize only their terms.
/// forge-config: default.fuzz.runs = 1000
contract SuperIMDPermitTest is SIMDPermitSigning {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    uint256 private constant HELD = 100 ether;
    uint256 private constant INITIAL_ALLOWANCE = 17 ether;
    uint256 private constant CURVE_ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    SuperIMD private token;
    address private holder;
    uint256 private holderKey;
    address private spender = makeAddr("permit spender");
    address private recipient = makeAddr("permit recipient");
    address private relayer = makeAddr("permit relayer");

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.warp(1_000_000);
        (holder, holderKey) = makeAddrAndKey("permit holder");
        token = new SuperIMD();
        token.transfer(holder, HELD);
        vm.prank(holder);
        token.approve(spender, INITIAL_ALLOWANCE);
    }

    function _signature(uint256 value, uint256 nonce, uint256 deadline) private view returns (Signature memory) {
        return _sign(token, holderKey, holder, spender, value, nonce, deadline);
    }

    function _submit(uint256 value, uint256 deadline, Signature memory sig) private {
        vm.prank(relayer);
        token.permit(holder, spender, value, deadline, sig.v, sig.r, sig.s);
    }

    function _assertAuthorizationOnly(uint256 nonce, uint256 allowed) private view {
        assertEq(token.nonces(holder), nonce);
        assertEq(token.allowance(holder, spender), allowed);
        assertEq(token.allowance(holder, relayer), 0);
        assertEq(token.nonces(spender), 0);
        assertEq(token.nonces(relayer), 0);
        assertEq(token.balanceOf(holder), HELD);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - HELD);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_permitAtExactDeadlineEmitsApproval() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _signature(1, 0, deadline);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(holder, spender, 1);
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(1, 1);
    }

    function test_expiredPermitPreservesNonceAndExistingApproval() public {
        uint256 deadline = vm.getBlockTimestamp();
        Signature memory sig = _signature(1, 0, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);

        // A failed request must leave nonce zero usable by a fresh, unexpired signature.
        deadline = vm.getBlockTimestamp() + 1;
        _submit(1, deadline, _signature(1, 0, deadline));
        _assertAuthorizationOnly(1, 1);
    }

    function test_wrongSignerPreservesNonceAndExistingApproval() public {
        (address stranger, uint256 key) = makeAddrAndKey("permit stranger");
        uint256 deadline = block.timestamp + 1;
        Signature memory sig = _sign(token, key, holder, spender, 1, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, stranger, holder));
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
    }

    function test_futureNonceCannotSkipAuthorizationSequence() public {
        uint256 deadline = type(uint256).max;
        Signature memory future = _signature(2, 1, deadline);
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(2, deadline, future);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);

        _submit(1, deadline, _signature(1, 0, deadline));
        _submit(2, deadline, future);
        _assertAuthorizationOnly(2, 2);
    }

    function test_zeroSpenderRevertsAndRollsBackNonce() public {
        uint256 deadline = block.timestamp + 1;
        Signature memory sig = _sign(token, holderKey, holder, address(0), 1, 0, deadline);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.permit(holder, address(0), 1, deadline, sig.v, sig.r, sig.s);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
        assertEq(token.allowance(holder, address(0)), 0);

        _submit(1, deadline, _signature(1, 0, deadline));
        _assertAuthorizationOnly(1, 1);
    }

    function test_zeroOwnerCannotBeAuthorizedByMalformedSignature() public {
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(address(0), spender, 1, block.timestamp, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(address(0)), 0);
        assertEq(token.allowance(address(0), spender), 0);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
    }

    function test_invalidVAndEmptySignatureDoNotConsumeNonce() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _signature(1, 0, deadline);
        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(holder, spender, 1, deadline, 0, sig.r, sig.s);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);

        vm.expectRevert(ECDSA.ECDSAInvalidSignature.selector);
        token.permit(holder, spender, 1, deadline, 27, bytes32(0), bytes32(0));
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(1, 1);
    }

    function test_malleatedHighSSignatureIsRejected() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _signature(1, 0, deadline);
        bytes32 highS = bytes32(CURVE_ORDER - uint256(sig.s));
        uint8 flippedV = sig.v == 27 ? 28 : 27;
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        token.permit(holder, spender, 1, deadline, flippedV, sig.r, highS);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(1, 1);
    }

    function test_signatureCannotBeReplayedOnAnotherDeployment() public {
        SuperIMD other = new SuperIMD();
        uint256 deadline = block.timestamp;
        Signature memory sig = _signature(1, 0, deadline);
        assertNotEq(token.DOMAIN_SEPARATOR(), other.DOMAIN_SEPARATOR());
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        other.permit(holder, spender, 1, deadline, sig.v, sig.r, sig.s);
        assertEq(other.nonces(holder), 0);
        assertEq(other.allowance(holder, spender), 0);
        assertEq(other.totalSupply(), SUPPLY);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(1, 1);
    }

    function test_chainChangeRebuildsDomainAndRejectsOldSignature() public {
        uint256 deadline = block.timestamp;
        Signature memory sig = _signature(1, 0, deadline);
        bytes32 originalDomain = token.DOMAIN_SEPARATOR();
        uint256 newChainId = _chainId() ^ 1;
        vm.chainId(newChainId);
        assertNotEq(token.DOMAIN_SEPARATOR(), originalDomain);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(token, newChainId));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(1, deadline, sig);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
        _submit(1, deadline, _signature(1, 0, deadline));
        _assertAuthorizationOnly(1, 1);
    }

    function test_domainIntrospectionDescribesSignedData() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "Super IMD");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
        assertEq(token.DOMAIN_SEPARATOR(), _domain(token, block.chainid));
    }

    function test_permitCanRevokeInfiniteApproval() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        _submit(0, block.timestamp, _signature(0, 0, block.timestamp));
        _assertAuthorizationOnly(1, 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        _assertAuthorizationOnly(1, 0);
    }

    function test_replayCannotRestoreSpentAllowance() public {
        uint256 deadline = block.timestamp + 1;
        Signature memory sig = _signature(HELD, 0, deadline);
        _submit(HELD, deadline, sig);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, HELD));
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        _submit(HELD, deadline, sig);
        assertEq(token.nonces(holder), 1);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), HELD);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_ordinaryApprovalAndTransferDoNotConsumePermitNonce() public {
        Signature memory sig = _signature(1, 0, block.timestamp);
        vm.startPrank(holder);
        token.approve(spender, 0);
        token.transfer(recipient, 1);
        vm.stopPrank();
        assertEq(token.nonces(holder), 0);
        _submit(1, block.timestamp, sig);
        assertEq(token.nonces(holder), 1);
        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(holder), HELD - 1);
        assertEq(token.balanceOf(recipient), 1);
    }

    function testFuzz_changingSignedFieldsCannotAuthorize(uint256 value, uint8 field) public {
        uint256 deadline = block.timestamp + 1;
        Signature memory sig = _signature(value, 0, deadline);
        address submittedOwner = holder;
        address submittedSpender = spender;
        uint256 submittedValue = value;
        uint256 submittedDeadline = deadline;
        field = uint8(bound(field, 0, 3));
        if (field == 0) submittedOwner = recipient;
        else if (field == 1) submittedSpender = recipient;
        else if (field == 2) submittedValue = value ^ 1;
        else submittedDeadline = deadline + 1;

        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        token.permit(submittedOwner, submittedSpender, submittedValue, submittedDeadline, sig.v, sig.r, sig.s);
        _assertAuthorizationOnly(0, INITIAL_ALLOWANCE);
        assertEq(token.nonces(recipient), 0);
        assertEq(token.allowance(recipient, spender), 0);
        assertEq(token.allowance(holder, recipient), 0);
        // The original signed terms remain usable after the rejected mutation.
        _submit(value, deadline, sig);
        _assertAuthorizationOnly(1, value);
    }

    function testFuzz_permitAuthorizesOnlySpenderAndExactAmount(uint256 allowed, uint256 spent) public {
        spent = bound(spent, 0, allowed < HELD ? allowed : HELD);
        _submit(allowed, block.timestamp, _signature(allowed, 0, block.timestamp));
        _assertAuthorizationOnly(1, allowed);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, relayer, 0, 1));
        token.transferFrom(holder, recipient, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, spent));
        assertEq(token.allowance(holder, spender), allowed == type(uint256).max ? allowed : allowed - spent);
        assertEq(token.nonces(holder), 1);
        assertEq(token.balanceOf(holder), HELD - spent);
        assertEq(token.balanceOf(recipient), spent);
        assertEq(token.balanceOf(relayer), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
