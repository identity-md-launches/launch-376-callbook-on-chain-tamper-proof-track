# CallBook

An on-chain, tamper-proof track record for trading calls. A trader publishes a price call without
revealing it, and after the call expires the contract settles it against Chainlink price rounds. Anyone
can then read the caller's real hit rate instead of trusting screenshots.

- `src/CallBook.sol` — the application contract.
- `src/LaunchToken.sol` — the fixed-supply launch token (`CallBook`, `CALL`, 18 decimals, 10^27 minor units).
- `script/Deploy.s.sol` — reviewable deploy script; `deploy(Config)` is the single deployment.
- `docs/abi/` — exported ABIs.
- `REVIEW.md` — self-review of the design and its residual risks.

## Rules

### Markets

The contract settles against Chainlink AggregatorV3 feeds. At deployment it lists two on Sepolia:

| Market  | Aggregator                                   | Decimals |
| ------- | -------------------------------------------- | -------- |
| ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | 8        |
| BTC/USD | `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` | 8        |

The owner can enable another feed with `addFeed(feed)` (at most 16 listed feeds) and stop new commits on
one with `disableFeed(feed)`. That is the owner's entire power. Disabling a feed does not touch calls
that already committed on it: they can still be revealed and settled.

### 1. Commit

```solidity
function commit(bytes32 commitHash, uint64 expiry) external returns (uint256 id);
commitHash = keccak256(abi.encode(caller, feed, direction, targetPrice, expiry, salt));
```

- `caller` is the address that will send `commit` and `reveal`.
- `feed` is the aggregator address. `direction` is `0` for UP and `1` for DOWN (ABI-encoded as `uint8`,
  which occupies a full 32-byte word like every other argument).
- `targetPrice` is an `int256` in the feed's own decimals (8 for both launch feeds).
- `expiry` must be between 1 hour and 30 days after the commit block's timestamp.
- `salt` is any secret `bytes32`. Without it the call could be brute-forced from the hash.

The contract records the latest round price of **every enabled feed** at commit time and emits a
`CommitPriceRecorded` event per feed. Because the hash hides which market the call is on, the contract
must snapshot all of them. A feed whose latest round is older than 3 hours, incomplete
(`updatedAt == 0` or `answeredInRound < roundId`) or non-positive makes `commit` revert with
`StalePrice(feed)`; the owner is expected to disable a broken feed.

### 2. Reveal

```solidity
function reveal(uint256 id, address feed, Direction direction, int256 targetPrice, bytes32 salt) external;
```

- Only the original caller, only once `block.timestamp >= expiry`, and only while
  `block.timestamp <= expiry + 24 hours`.
- The preimage must hash to the committed value. The expiry used in the hash is the one stored at commit.
- The feed must have been enabled at commit time (a commit price must exist for it).
- `targetPrice` must be positive and on the correct side of the commit price: strictly above it for UP,
  strictly below it for DOWN. A target on the wrong side would be a call that had already "hit".

`revealAndSettle(id, feed, direction, targetPrice, salt, roundId)` does steps 2 and 3 in one transaction.

### 3. Settle

```solidity
function settle(uint256 id, uint80 roundId) external;
```

Anyone can settle a revealed call.

- **HIT with proof.** Pass the id of a Chainlink round on the call's feed with `updatedAt` inside
  `[committedAt, expiry]` (both inclusive) whose answer reached the target: `answer >= target` for UP,
  `answer <= target` for DOWN. The contract reads `getRoundData(roundId)` and rejects rounds that are
  incomplete or stale (`updatedAt == 0`, `answeredInRound < roundId`, returned id differs), outside the
  window, or with a non-positive answer. A round that is valid but did not reach the target reverts with
  `NotAHit` and changes nothing, so a bad proof cannot be used to record a MISS.
- **MISS without proof.** Pass `roundId == 0`. The caller may do this at any time after revealing.
  Anyone else may do it only once the reveal window (`expiry + 24 hours`) has closed. This stops a third
  party from front-running the caller's own proof with a premature MISS. A HIT proof is accepted from
  anyone at any time while the call is still unsettled.

### 4. Unrevealed calls count as misses

```solidity
function markUnrevealed(uint256 id) external;
```

Once `block.timestamp > expiry + 24 hours`, anyone can mark a still-committed call as a MISS. The call's
record carries `forced = true`. Callers cannot hide bad calls by never revealing them.

### Record

```solidity
function getStats(address caller) external view returns (Stats memory);
// Stats { uint64 calls; uint64 hits; uint64 misses; uint64 currentStreak; uint64 bestStreak; }
```

- `calls` counts commits. `calls - hits - misses` is the number of pending calls.
- Streaks follow settlement order: a HIT increments `currentStreak` (and `bestStreak` when exceeded); any
  MISS, forced or not, resets `currentStreak` to zero.

`getCall(id)` returns the full call record, `commitPriceOf(id, feed)` the snapshot, `feeds()` every feed
ever listed, `feedEnabled(feed)` whether it takes new commits, and `feedDecimals(feed)` the scale for
targets. `hashCall(...)` mirrors the commit hash computation for convenience.

Events: `Committed`, `CommitPriceRecorded`, `Revealed`, `Settled(id, caller, hit, proofRoundId, forced)`,
`FeedEnabled`, `FeedDisabled`.

The contract has no `receive` or `fallback`, holds no ETH or tokens, and charges no fees.

## Worked example

Alice thinks ETH will trade above $2,500 within the next day. ETH/USD is at $2,000 (answer `200000000000`
with 8 decimals).

1. **Commit** at time `T`. She picks `expiry = T + 86400` and a random salt, and computes
   `hash = keccak256(abi.encode(alice, ETH_USD, 0 /* UP */, 250000000000, expiry, salt))`.
   She calls `commit(hash, expiry)` and gets `id = 1`. The contract records `commitPriceOf(1, ETH_USD)
   = 200000000000` and `commitPriceOf(1, BTC_USD)` as well, and increments `getStats(alice).calls`.
2. **Prices move.** Twelve hours later Chainlink posts round `R` with answer `260000000000` at
   `updatedAt = T + 43200`. By expiry the price has fallen back to $2,100.
3. **Reveal** at `T + 86400` or later (but before `T + 172800`): Alice calls
   `reveal(1, ETH_USD, 0, 250000000000, salt)`. The contract checks the hash, that ETH/USD was recorded at
   commit, and that `250000000000 > 200000000000`.
4. **Settle.** Alice, or anyone, calls `settle(1, R)`. The contract reads round `R`, confirms
   `T <= T + 43200 <= T + 86400` and `260000000000 >= 250000000000`, and records a HIT. Passing the final
   round (answer $2,100) instead would revert with `NotAHit`. Alice could have done steps 3 and 4 at once
   with `revealAndSettle(1, ETH_USD, 0, 250000000000, salt, R)`.
5. **Record.** `getStats(alice)` now shows `calls = 1, hits = 1, misses = 0, currentStreak = 1,
   bestStreak = 1`.

Had ETH never printed a round at or above $2,500, Alice would call `settle(1, 0)` to take the MISS, or
anyone could do so after `T + 172800`. Had she not revealed at all, anyone could call
`markUnrevealed(1)` after `T + 172800` and the MISS would be recorded with `forced = true`.

## Assumptions

- Chainlink is the only price source. A HIT requires a posted round; a price that touched the target
  between two rounds without being reported cannot be proven, and that is by design.
- Feed answers are compared as raw `int256` in the feed's decimals. Targets must use the same scale;
  a target in the wrong scale is rejected at reveal only when it lands on the wrong side of the commit
  price.
- The commit snapshot only enforces that the target is on the correct side of the price the caller saw.
  It tolerates a latest round up to 3 hours old, which is three times the launch feeds' heartbeat.
- Rounds are identified by Chainlink's phase-encoded `uint80` round ids as returned by the proxy.
- Block timestamps bound the reveal window and the settlement window. A builder can nudge a timestamp by
  seconds, not by the hours these windows span.
- The reveal window is 24 hours after expiry. A caller who is offline for that whole day takes a forced
  MISS; that cost is deliberate and is what makes the record tamper-proof.
- Streaks are computed in settlement order, not commit order, because settlement is the first moment an
  outcome is known.

## Build and test (offline)

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "paris"`, `optimizer_runs = 200`,
`bytecode_hash = "none"`, `ffi = false` and no filesystem permissions. `lib/forge-std` is vendored as
plain files. Tests read no environment variables and pass in any order.

## Deployment parameters

The launch deploys through the IdentityMD ProjectFactory. `LaunchToken` has no constructor arguments.
`CallBook` takes three `address` arguments, in order:

| Argument | Value on Sepolia                                              |
| -------- | ------------------------------------------------------------- |
| `owner_` | `$owner` (the policy's project owner; never the factory)      |
| `ethUsd` | `0x694AA1769357215DE4FAC081bf1f309aDC325306` (Chainlink ETH/USD) |
| `btcUsd` | `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43` (Chainlink BTC/USD) |

The constructor is nonpayable, makes no external calls, and the runtime contains no `DELEGATECALL`,
`CALLCODE` or `SELFDESTRUCT`. Because the factory is `msg.sender` during construction, the owner must be
passed explicitly; `msg.sender` would hand feed management to an immutable factory that cannot use it.

The script equivalent for an operator (dry run shown; the operator supplies their own signer flags and
never commits a key):

```sh
EXPECTED_CHAIN_ID=11155111 CALLBOOK_OWNER=<owner> forge script script/Deploy.s.sol:Deploy --rpc-url <sepolia>
```

`run()` refuses any chain other than Anvil (31337) or Sepolia (11155111), and `CALLBOOK_ETH_USD` /
`CALLBOOK_BTC_USD` default to the Sepolia feeds above.

## Operational responsibilities

- **Owner.** Disable a feed whose aggregator stops updating (commits revert with `StalePrice(feed)`
  while it is enabled) or is deprecated by Chainlink. Enable a replacement with `addFeed`. The owner has
  no other power: it cannot settle, cancel, edit or delete a call, and ownership is immutable.
- **Callers.** Keep the salt and the call parameters; without them the call cannot be revealed and
  becomes a forced MISS. Reveal within 24 hours of expiry. Submit the proving round id, or use
  `revealAndSettle`, before the reveal window closes if a third party might otherwise settle a MISS.
- **Anyone (keepers, readers).** Call `markUnrevealed` on stale committed calls and `settle(id, 0)` on
  stale revealed ones after the reveal window, so that records stay current. Find proving rounds by
  scanning the feed's `AnswerUpdated` events or its round history between `committedAt` and `expiry`.
- **Nobody** holds funds here. There is nothing to sweep, pause or upgrade.
