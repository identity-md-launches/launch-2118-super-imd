// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "src/SuperIMD.sol";

// Foundry 1.8 exposes this cheatcode; the repository's vendored Vm interface predates it.
interface SIMDChainIdCheatcode {
    function getChainId() external view returns (uint256);
}

/// @dev Test-only ERC-2612 encoder. Derive the domain from the specified metadata, chain and
/// deployment address, rather than using the token's DOMAIN_SEPARATOR as the signing oracle.
abstract contract SIMDPermitSigning is Test {
    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function _chainId() internal view returns (uint256) {
        // An external read prevents the optimizer from caching CHAINID across vm.chainId calls.
        return SIMDChainIdCheatcode(address(vm)).getChainId();
    }

    function _domain(SuperIMD token, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Super IMD"),
                keccak256("1"),
                chainId,
                address(token)
            )
        );
    }

    function _sign(
        SuperIMD token,
        uint256 key,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (Signature memory sig) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked(hex"1901", _domain(token, _chainId()), structHash));
        (sig.v, sig.r, sig.s) = vm.sign(key, digest);
    }
}
