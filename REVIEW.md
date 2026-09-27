# REVIEW.md — CallBook self-review

This is the builder's own adversarial pass over `src/CallBook.sol` and `src/LaunchToken.sol`. It is not an
independent audit. The contract holds no funds, so the attack surface is the integrity of the record:
can a caller hide a bad call, fake a good one, or damage someone else's record?

## What was re-run

```
forge build --offline          # solc 0.8.26, paris, optimizer 200
forge test --offline           # 49 tests, 6 fuzz (256 runs each), all pass
forge fmt --check              # clean
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline   # dry run ok
```

A scratch harness (`test/scratch/Floor.t.sol`, not shipped) reproduced the protected deployment floor:
both contracts deployed via CREATE2 from a factory address with the Sepolia feed addresses holding no
code, the launch supply stayed with the factory, and the runtime scan found no `DELEGATECALL`,
`CALLCODE` or `SELFDESTRUCT`. CallBook runtime is 7,013 bytes.

## Findings and disposition

| # | Concern | Disposition |
|---|---------|-------------|
| 1 | **Premature MISS griefing.** If anyone could settle a revealed call as a MISS with no proof, a third party could front-run the caller's proof transaction. | Fixed by design: a no-proof MISS from a non-caller is only accepted after the reveal window closes; `revealAndSettle` lets the caller reveal and prove atomically. Tested in `test_settle_thirdPartyMissOnlyAfterRevealWindow`. |
| 2 | **Bad proof used to force a MISS.** A settler could pass a round that did not reach the target. | Rejected: a valid round that misses the target reverts with `NotAHit` and leaves the call `Revealed`. Tested. |
| 3 | **Round outside the window.** A round before commit or after expiry proving a HIT. | Rejected by inclusive bounds on `updatedAt`. Fuzzed in `testFuzz_settle_roundTimestampWindow`. |
| 4 | **Stale or incomplete rounds.** `updatedAt == 0`, `answeredInRound < roundId`, mismatched id, non-positive answer. | Rejected at settle and at commit snapshot. Tested. |
| 5 | **Target already reached at commit.** UP with target at or below the commit price would be a free HIT. | Rejected at reveal (`TargetWrongSide`); the bound is strict. Fuzzed. |
| 6 | **Hiding a loss by not revealing.** | Anyone can `markUnrevealed` after the window; forced MISS resets the streak. Tested. |
| 7 | **Hash flexibility.** Could a caller commit once and reveal one of several calls? | The hash binds caller, feed, direction, target, expiry and salt; expiry is taken from storage, not the argument. Any change reverts with `HashMismatch`. Tested per field. |
| 8 | **Brute-forcing a commit hash.** Without a salt the search space is small (feed x direction x round target). | Salt is part of the preimage; README tells callers to use a random `bytes32`. A weak salt only hurts the caller's own secrecy, never the record. |
| 9 | **Owner power over results.** | Owner can only enable or disable feeds, is immutable, and cannot touch any call. Disabling a feed does not block reveal or settle of existing calls. Tested in `test_reveal_andSettleStillWorkAfterFeedDisabled`. |
| 10 | **Owner adds a malicious "feed".** A fake aggregator would let the owner's friends prove anything on that feed. | Accepted and documented: this is the ordinary trust in the feed list, and every call names its feed in `Revealed`, so readers can filter by feed. `addFeed` at least checks the address answers `decimals()`. |
| 11 | **Unbounded loop at commit.** Every enabled feed is read. | Bounded by `MAX_FEEDS = 16`; disabled feeds are skipped with one SLOAD. |
| 12 | **One stale feed blocks all commits.** | Accepted trade-off: the alternative (silently skipping) creates calls that can never be revealed and become forced misses. Owner responsibility documented. |
| 13 | **Reentrancy.** External calls are to aggregators, all `view`, and the contract holds nothing. | No state written after an external call except in `commit`, where the loop reads feeds and writes the snapshot; a malicious feed could only revert or return garbage, which affects the callers who chose it. |
| 14 | **Timestamp manipulation.** | Windows span hours; a builder's seconds of drift do not matter. Boundaries are tested exactly (`>=` at expiry, `<=` at window end). |
| 15 | **Counter overflow.** `uint64` stats and `uint256` ids. | Unreachable in practice; arithmetic is checked. |
| 16 | **Streak semantics.** Settlement order differs from commit order. | Documented; deliberate, since an outcome is only known at settlement. |
| 17 | **LaunchToken.** | No owner, no mint, no hooks, constant supply, exact-amount transfers, no `DELEGATECALL` / `SELFDESTRUCT`. Tested including a fuzzed conservation check. |

## Edges not covered by tests

- Chainlink phase changes: a proof round from an earlier phase is handled by the proxy's `getRoundData`,
  but there is no mock for phase-encoded ids.
- Real Sepolia feed behaviour (heartbeat gaps longer than 3 hours) is not exercised; it would surface as
  `StalePrice` on commit and is an owner action, not a code path.
- Gas at `MAX_FEEDS` enabled is not measured; at 16 external calls plus 16 SSTOREs it remains well under
  any block limit.
