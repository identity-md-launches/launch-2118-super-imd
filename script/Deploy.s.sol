// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SuperIMD} from "../src/SuperIMD.sol";

/// @title Deploy script for Super IMD
/// @notice For local and test-network use only. The production launch on Ethereum is performed by the
/// IdentityMD ProjectFactory from the attested bytecode, not by this script. The token takes no
/// constructor arguments, so there is no configuration to read: the broadcasting account becomes the
/// deployer and receives the whole supply.
contract DeploySuperIMD is Script {
    /// @notice Deploys the token. Tests call this directly; `run()` wraps it in a broadcast.
    function deploy() public returns (SuperIMD token) {
        token = new SuperIMD();
    }

    /// @notice Entry point for `forge script`. The signer is supplied on the command line
    /// (`--private-key`, `--ledger`, ...); nothing is read from the environment here.
    function run() external returns (SuperIMD token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
