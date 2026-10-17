# Super IMD tests

The tests use the repository's existing Solidity dependencies and require no fork,
network access, environment mutation, or additional installation.

Run from the repository root with the verifier's seed:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xed669865e65bb5335985d3194e8cffd76c052e8313ce88587bb82d8402b1b3b0 forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Generated build artifacts stay under `test/scratch/`. No delivered test imports
anything from that directory. Fuzz and invariant run counts are set inline in the
test contracts.

- `SuperIMD.t.sol` checks metadata, the exact constructor allocation and single mint
  event, ordinary ERC-20 behavior, and the absence of privileged entry points.
- `SuperIMD.edges.t.sol` adds zero, one wei, full-supply, and maximum-integer cases;
  authorization isolation and revocation; rollback after rejected transfers;
  and transfer round-trip and split-payment properties.
- `SuperIMD.permit.t.sol` exercises ERC-2612, including deadline boundaries,
  signature mutations, replay, malformed and malleated signatures, nonce rollback,
  and separation between chains and token deployments. Its signing helper derives
  the domain independently from the specified metadata.
- `SuperIMD.invariant.t.sol` runs 256 random sequences of 64 actions among six funded
  actors. Independent ghost state tracks balances, allowances and permit nonces.
  Actions include transfers, approvals, delegated transfers, permits, replays, and
  deliberately invalid operations. Unexpected handler reverts fail the campaign.
  Inputs explicitly include zero, dust, full balances, and finite/infinite approvals.
  After each sequence, every holder transfers its full balance back to one actor
  to check that the funds remain transferable.
- `LaunchFlow.t.sol` retains the existing factory deployment and token payout
  fixtures. These simulate token movements; they do not deploy a Uniswap pool or
  replace the supplied protected launch integration checks.

No token storage or balances are patched with cheatcodes. Initial invariant
balances come from constructor minting and real transfers. Rejected operations
leave ghost state unchanged, so the invariants also verify rollback and isolation.
