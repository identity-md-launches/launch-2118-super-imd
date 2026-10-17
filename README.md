# Super IMD (SIMD)

A fixed-supply ERC-20 token for an IdentityMD custom-token launch on Ethereum mainnet.

| Field | Value |
|-------|-------|
| Solidity contract | `SuperIMD` (`src/SuperIMD.sol`) |
| `name()` | `Super IMD` |
| `symbol()` | `SIMD` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 SIMD = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Minting | once, in the constructor, the whole supply to `msg.sender` (the deployer) |
| Owner / admin | none |
| Standards | ERC-20, ERC-2612 `permit`, ERC-5267 `eip712Domain` |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## Behaviour

- The constructor mints `TOTAL_SUPPLY` to `msg.sender` and emits one `Transfer(address(0), deployer, 1e27)`.
  It takes no arguments and makes no external calls, so it deploys on an empty chain.
- Transfers, approvals and `transferFrom` are plain OpenZeppelin v5.4.0 ERC-20 semantics: no fee, no
  burn, no reflection, no hook, no exemptions. Every transfer moves exactly the amount requested.
- There is no `mint`, `owner`, `pause`, blocklist, freeze, `burnFrom` or upgrade path. The total supply
  can never increase after deployment, and no address other than a holder (or a spender the holder
  approved) can move a holder's balance.
- `permit` (ERC-2612) lets a holder grant an allowance by signature. The EIP-712 domain is
  `name = "Super IMD"`, `version = "1"`, bound to the chain id and the token address.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (checked by a test that scans the
  deployed bytecode), and the contract uses no external libraries, so the bytecode has no link placeholders.

## Assumptions

- The deployer is whoever calls the constructor. Under the IdentityMD launch that is the ProjectFactory,
  which receives the full 1e27 and pays it out itself (10% to the launch's MerkleDistributor, 80% to the
  Uniswap v4 pool seed, the remaining 10% to the requester's `remainderTo`). Nothing in this contract is
  allocated, reserved or exempted; the token simply has no transfer rules that could interfere with those
  flows.
- "1,000,000,000 with 18 decimals" is read as 1,000,000,000 whole tokens, i.e. 1e27 minor units. That is
  what `token.totalSupply` in the manifest must state.
- No values are left open by the brief: there is no fee, tax, owner, treasury or external contract, so
  there are no owner-settable settings and nothing to configure after launch.

## Deployment parameters

The production launch is performed by IdentityMD's deployer through the ProjectFactory, from the
bytecode as built here. The values below are the launch's and are recorded by the manifest step, not by
this repository:

- Chain: Ethereum (chain id 1).
- Token contract name: `SuperIMD`; `constructorArgs`: `[]`; `decimals`: `18`;
  `totalSupply`: `"1000000000000000000000000000"`.
- Pool: paired with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee `12500`, tick spacing `60`,
  provenance price `"79228162514264337593543950336"` (the deployer derives the real opening price from
  the economics).
- Economics (requester's, copied verbatim): `poolBps` 8000, `initialMarketCapWei`
  `25000000000000000000000` (25,000 IMD), `remainderTo` `0x612a9bB008e16ef2D24f41DAe9Fc661831d93367`.
- Application contracts: none. This launch is the token alone.

For local or test-network use, `script/Deploy.s.sol` exposes `deploy()` (called directly by the tests) and
a `run()` wrapper. It reads nothing from the environment; the signer is passed on the `forge script`
command line and becomes the deployer that receives the supply.

```sh
forge script script/Deploy.s.sol:DeploySuperIMD --rpc-url <RPC> --private-key <KEY> --broadcast
```

## After launch

There are no owner-settable values and no admin functions. Nothing needs to be configured.

## Operational responsibilities

- **Requester**: keep control of the `remainderTo` wallet; it receives 10% of the supply at launch.
  The token has no recovery path for tokens sent to the wrong address or to the token contract itself.
- **IdentityMD deployer / launch policy**: deploy from the attested bytecode, write the manifest with the
  values above, verify the source on the explorer after deployment (`forge verify-contract` with
  solc 0.8.26, optimizer 200 runs, no metadata hash) and seed the pool. These steps are outside this
  repository's authority; no transaction is broadcast from here.
- **Holders**: `permit` signatures are valid until their deadline; sign only for trusted spenders and
  use short deadlines. Infinite approvals (`type(uint256).max`) are never decremented.
- **Independent review**: tests passing are not an audit. The token is a thin wrapper over audited
  OpenZeppelin v5.4.0 code, but the launch policy's separate adversarial review still applies before
  release.

## Security notes

Checked against the eth-security reference for this task:

- No reentrancy surface: the token makes no external calls (permit uses the `ecrecover` precompile only).
- No decimals mismatch: `decimals()` is a constant 18 and the manifest states 18.
- No admin keys, no `Ownable`, no proxy, no `selfdestruct`, no `delegatecall`.
- No arithmetic beyond OpenZeppelin's checked ERC-20 accounting; Solidity 0.8 overflow checks are on.
- Tools run: `forge build`, `forge test` (unit, fuzz with the verifier's seed, invariant), `forge fmt --check`.
  Slither and Mythril were not available in this environment and did not run.

## Layout

```
foundry.toml                 compiler pin, bytecode_hash = "none", no ffi, no fs access
remappings.txt               forge-std and @openzeppelin/contracts
src/SuperIMD.sol             the token
script/Deploy.s.sol          local deploy helper (not used by the launch)
test/SuperIMD.t.sol          unit and fuzz tests
test/LaunchFlow.t.sol        the launch's payout flows replayed against a factory stand-in
test/SuperIMD.invariant.t.sol supply-conservation invariants
lib/forge-std                forge-std v1.9.7, vendored as plain files
lib/openzeppelin-contracts   OpenZeppelin Contracts v5.4.0 (contracts/ only), vendored as plain files
```

## Running the checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0xed669865e65bb5335985d3194e8cffd76c052e8313ce88587bb82d8402b1b3b0 forge test
forge fmt --check
```

Tests read no environment variables, depend on no caller address and pass in any order and in parallel.
