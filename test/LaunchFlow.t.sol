// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SuperIMD} from "../src/SuperIMD.sol";

/// @notice Stands in for the IdentityMD ProjectFactory: deploys the token with CREATE2 so the supply
/// lands on it, then pays the supply out the way the launch does.
contract FactoryStub {
    function deploy(bytes32 salt) external returns (SuperIMD token) {
        token = new SuperIMD{salt: salt}();
    }

    function pay(SuperIMD token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

/// @notice The launch flows the custom-token floor checks, replayed locally: the whole supply minted to
/// the factory, ten percent forwarded whole to the distributor and claimable whole, eighty percent
/// available for the pool seed, the remainder forwarded whole, and the supply unchanged throughout.
contract LaunchFlowTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_000;
    address internal constant REMAINDER_TO = 0x612a9bB008e16ef2D24f41DAe9Fc661831d93367;

    FactoryStub internal factory;
    SuperIMD internal token;
    address internal distributor = makeAddr("distributor");
    address internal claimant = makeAddr("claimant");
    address internal poolManager = makeAddr("poolManager");
    address internal trader = makeAddr("trader");

    function setUp() public {
        factory = new FactoryStub();
        token = factory.deploy(bytes32(uint256(1)));
    }

    function test_supplyIsMintedToTheFactoryOnly() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_create2AddressIsPredictableFromCreationCode() public {
        bytes32 salt = bytes32(uint256(42));
        bytes32 initHash = keccak256(type(SuperIMD).creationCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, initHash)))));
        SuperIMD deployed = factory.deploy(salt);
        assertEq(address(deployed), predicted);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
    }

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.pay(token, distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm);
        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm);
        assertEq(token.balanceOf(distributor), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fullPayoutSplitsSupplyExactly() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.pay(token, distributor, swarm));
        assertTrue(factory.pay(token, poolManager, pool));
        assertTrue(factory.pay(token, REMAINDER_TO, remainder));

        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(poolManager), 800_000_000 ether);
        assertEq(token.balanceOf(REMAINDER_TO), 100_000_000 ether);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolRoundTripMovesExactAmounts() public {
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        factory.pay(token, poolManager, pool);

        // Buy: the pool manager pays the trader out; sell: the trader pays the pool manager back.
        uint256 bought = 12_345 ether;
        vm.prank(poolManager);
        assertTrue(token.transfer(trader, bought));
        assertEq(token.balanceOf(trader), bought);
        vm.prank(trader);
        assertTrue(token.transfer(poolManager, bought));
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.balanceOf(poolManager), pool);
    }

    function test_factoryCannotPayMoreThanTheSupply() public {
        vm.expectRevert();
        factory.pay(token, distributor, SUPPLY + 1);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
    }

    function test_supplyCannotGrowAfterLaunch() public {
        bytes memory data = abi.encodeWithSignature("mint(address,uint256)", address(factory), 1);
        vm.prank(address(factory));
        (bool ok,) = address(token).call(data);
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
