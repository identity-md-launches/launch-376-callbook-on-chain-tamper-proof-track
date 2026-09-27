// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title CallBook
/// @notice An on-chain, tamper-proof track record for price calls settled against Chainlink feeds.
///
/// A trader commits to a hidden call (feed, direction, target price, expiry) by publishing only a hash.
/// At commit time the contract snapshots the fresh price of every enabled feed, so the reveal can be
/// checked against the price the caller actually saw. After expiry the caller reveals the preimage.
/// Anyone can then settle the call: a HIT needs a Chainlink round (with updatedAt inside the call's
/// window) whose answer reached the target; without such a proof the call is a MISS. A call that is
/// never revealed within the reveal window is marked a MISS by anyone, so bad calls cannot be hidden.
///
/// The contract holds no tokens and no ETH, charges no fees, and the owner can only enable or
/// disable feeds. Nothing the owner does changes the result of a call that has already been made.
contract CallBook {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Direction {
        UP,
        DOWN
    }

    enum Status {
        None,
        Committed,
        Revealed,
        Hit,
        Miss
    }

    struct Call {
        address caller;
        uint64 committedAt;
        uint64 expiry;
        Status status;
        Direction direction;
        /// @dev True when the MISS was recorded because the call was never revealed.
        bool forced;
        address feed;
        bytes32 commitHash;
        /// @dev Price of `feed` recorded at commit time (copied from the snapshot at reveal).
        int256 commitPrice;
        int256 targetPrice;
        /// @dev Round that proved the HIT; zero for a MISS.
        uint80 proofRoundId;
        uint64 settledAt;
    }

    struct Stats {
        uint64 calls;
        uint64 hits;
        uint64 misses;
        uint64 currentStreak;
        uint64 bestStreak;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Shortest allowed time between commit and expiry.
    uint256 public constant MIN_DURATION = 1 hours;
    /// @notice Longest allowed time between commit and expiry.
    uint256 public constant MAX_DURATION = 30 days;
    /// @notice Time after expiry during which the caller may reveal.
    uint256 public constant REVEAL_WINDOW = 24 hours;
    /// @notice Maximum age of a feed's latest round for it to be snapshotted at commit.
    uint256 public constant MAX_PRICE_AGE = 3 hours;
    /// @notice Upper bound on listed feeds, which bounds the commit loop.
    uint256 public constant MAX_FEEDS = 16;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice The only privileged account. It can add and disable feeds and nothing else.
    address public immutable owner;

    address[] private _feeds;
    /// @notice True once a feed address has been listed (listing is permanent, enabling is not).
    mapping(address feed => bool) public isListed;
    /// @notice True while a feed accepts new commits.
    mapping(address feed => bool) public feedEnabled;

    /// @notice Number of calls committed so far. Call ids run from 1 to `callCount`.
    uint256 public callCount;
    mapping(uint256 id => Call) private _calls;
    /// @notice Price of `feed` recorded when call `id` was committed; zero when not recorded.
    mapping(uint256 id => mapping(address feed => int256 price)) public commitPriceOf;
    mapping(address caller => Stats) private _stats;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event FeedEnabled(address indexed feed);
    event FeedDisabled(address indexed feed);
    event Committed(uint256 indexed id, address indexed caller, bytes32 commitHash, uint64 committedAt, uint64 expiry);
    event CommitPriceRecorded(uint256 indexed id, address indexed feed, uint80 roundId, int256 price);
    event Revealed(
        uint256 indexed id,
        address indexed caller,
        address indexed feed,
        Direction direction,
        int256 targetPrice,
        int256 commitPrice
    );
    event Settled(uint256 indexed id, address indexed caller, bool hit, uint80 proofRoundId, bool forced);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error FeedNotEnabled();
    error TooManyFeeds();
    error EmptyHash();
    error BadExpiry();
    error NoFeeds();
    error StalePrice(address feed);
    error BadAnswer();
    error NotCommitted();
    error NotRevealed();
    error NotCaller();
    error NotExpired();
    error RevealWindowClosed();
    error RevealWindowOpen();
    error HashMismatch();
    error FeedNotRecorded();
    error BadTarget();
    error TargetWrongSide();
    error IncompleteRound();
    error RoundOutsideWindow();
    error NotAHit();

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @param owner_ Account allowed to enable and disable feeds.
    /// @param ethUsd Chainlink ETH/USD aggregator (Sepolia: 0x694AA1769357215DE4FAC081bf1f309aDC325306).
    /// @param btcUsd Chainlink BTC/USD aggregator (Sepolia: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43).
    /// @dev Makes no external calls so it can be deployed through a factory before feeds are live.
    constructor(address owner_, address ethUsd, address btcUsd) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        _enable(ethUsd);
        _enable(btcUsd);
    }

    // ---------------------------------------------------------------------
    // Owner: feed management only
    // ---------------------------------------------------------------------

    /// @notice Enable a feed for new commits. Lists it on first use; re-enables a disabled feed.
    function addFeed(address feed) external {
        if (msg.sender != owner) revert NotOwner();
        // Sanity-check that the address answers like an aggregator before exposing it to callers.
        AggregatorV3Interface(feed).decimals();
        _enable(feed);
    }

    /// @notice Stop accepting new commits on a feed. Calls already committed on it are unaffected.
    function disableFeed(address feed) external {
        if (msg.sender != owner) revert NotOwner();
        if (!feedEnabled[feed]) revert FeedNotEnabled();
        feedEnabled[feed] = false;
        emit FeedDisabled(feed);
    }

    function _enable(address feed) private {
        if (feed == address(0)) revert ZeroAddress();
        if (!isListed[feed]) {
            if (_feeds.length >= MAX_FEEDS) revert TooManyFeeds();
            isListed[feed] = true;
            _feeds.push(feed);
        }
        if (!feedEnabled[feed]) {
            feedEnabled[feed] = true;
            emit FeedEnabled(feed);
        }
    }

    // ---------------------------------------------------------------------
    // Commit
    // ---------------------------------------------------------------------

    /// @notice Publish a hidden call.
    /// @param commitHash keccak256(abi.encode(msg.sender, feed, direction, targetPrice, expiry, salt)).
    /// @param expiry Unix time at which the call ends; between 1 hour and 30 days from now.
    /// @return id The call id.
    /// @dev Snapshots the fresh price of every enabled feed. Reverts if any enabled feed is stale, so
    /// the owner must disable a broken feed to keep commits flowing.
    function commit(bytes32 commitHash, uint64 expiry) external returns (uint256 id) {
        if (commitHash == bytes32(0)) revert EmptyHash();
        if (expiry < block.timestamp + MIN_DURATION || expiry > block.timestamp + MAX_DURATION) revert BadExpiry();

        id = ++callCount;
        Call storage c = _calls[id];
        c.caller = msg.sender;
        c.committedAt = uint64(block.timestamp);
        c.expiry = expiry;
        c.status = Status.Committed;
        c.commitHash = commitHash;

        uint256 recorded;
        uint256 n = _feeds.length;
        for (uint256 i; i < n; ++i) {
            address feed = _feeds[i];
            if (!feedEnabled[feed]) continue;
            (uint80 roundId, int256 price) = _freshPrice(feed);
            commitPriceOf[id][feed] = price;
            emit CommitPriceRecorded(id, feed, roundId, price);
            ++recorded;
        }
        if (recorded == 0) revert NoFeeds();

        ++_stats[msg.sender].calls;
        emit Committed(id, msg.sender, commitHash, uint64(block.timestamp), expiry);
    }

    function _freshPrice(address feed) private view returns (uint80 roundId, int256 answer) {
        uint256 updatedAt;
        uint80 answeredInRound;
        (roundId, answer,, updatedAt, answeredInRound) = AggregatorV3Interface(feed).latestRoundData();
        if (updatedAt == 0 || answeredInRound < roundId || updatedAt > block.timestamp) revert StalePrice(feed);
        if (block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePrice(feed);
        if (answer <= 0) revert BadAnswer();
    }

    // ---------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------

    /// @notice Reveal a call after its expiry. Only the caller, only within REVEAL_WINDOW of expiry.
    /// @param targetPrice Target in the feed's own decimals; must be above the commit price for UP and
    /// below it for DOWN.
    function reveal(uint256 id, address feed, Direction direction, int256 targetPrice, bytes32 salt) external {
        _reveal(id, feed, direction, targetPrice, salt);
    }

    /// @notice Reveal and settle in one transaction. Pass `roundId == 0` to settle as a MISS.
    function revealAndSettle(
        uint256 id,
        address feed,
        Direction direction,
        int256 targetPrice,
        bytes32 salt,
        uint80 roundId
    ) external {
        _reveal(id, feed, direction, targetPrice, salt);
        _settle(id, roundId);
    }

    function _reveal(uint256 id, address feed, Direction direction, int256 targetPrice, bytes32 salt) private {
        Call storage c = _calls[id];
        if (c.status != Status.Committed) revert NotCommitted();
        if (msg.sender != c.caller) revert NotCaller();
        if (block.timestamp < c.expiry) revert NotExpired();
        if (block.timestamp > uint256(c.expiry) + REVEAL_WINDOW) revert RevealWindowClosed();
        if (keccak256(abi.encode(msg.sender, feed, direction, targetPrice, c.expiry, salt)) != c.commitHash) {
            revert HashMismatch();
        }

        int256 commitPrice = commitPriceOf[id][feed];
        if (commitPrice == 0) revert FeedNotRecorded();
        if (targetPrice <= 0) revert BadTarget();
        if (direction == Direction.UP ? targetPrice <= commitPrice : targetPrice >= commitPrice) {
            revert TargetWrongSide();
        }

        c.status = Status.Revealed;
        c.feed = feed;
        c.direction = direction;
        c.targetPrice = targetPrice;
        c.commitPrice = commitPrice;
        emit Revealed(id, msg.sender, feed, direction, targetPrice, commitPrice);
    }

    // ---------------------------------------------------------------------
    // Settle
    // ---------------------------------------------------------------------

    /// @notice Settle a revealed call.
    /// @param roundId A Chainlink round proving the HIT, or 0 to settle as a MISS.
    /// @dev A HIT proof is accepted from anyone at any time while the call is Revealed. A MISS without
    /// proof is accepted from the caller at any time, and from anyone else only once the reveal window
    /// has closed, so a third party cannot front-run a caller's proof with a premature MISS.
    function settle(uint256 id, uint80 roundId) external {
        _settle(id, roundId);
    }

    function _settle(uint256 id, uint80 roundId) private {
        Call storage c = _calls[id];
        if (c.status != Status.Revealed) revert NotRevealed();

        if (roundId == 0) {
            if (msg.sender != c.caller && block.timestamp <= uint256(c.expiry) + REVEAL_WINDOW) {
                revert RevealWindowOpen();
            }
            _finish(id, c, false, 0, false);
            return;
        }

        (uint80 rid, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(c.feed).getRoundData(roundId);
        if (rid != roundId || updatedAt == 0 || answeredInRound < roundId) revert IncompleteRound();
        if (updatedAt < c.committedAt || updatedAt > c.expiry) revert RoundOutsideWindow();
        if (answer <= 0) revert BadAnswer();

        bool hit = c.direction == Direction.UP ? answer >= c.targetPrice : answer <= c.targetPrice;
        if (!hit) revert NotAHit();
        _finish(id, c, true, roundId, false);
    }

    /// @notice Record a MISS for a call that was never revealed. Anyone may call once the reveal window closed.
    function markUnrevealed(uint256 id) external {
        Call storage c = _calls[id];
        if (c.status != Status.Committed) revert NotCommitted();
        if (block.timestamp <= uint256(c.expiry) + REVEAL_WINDOW) revert RevealWindowOpen();
        _finish(id, c, false, 0, true);
    }

    function _finish(uint256 id, Call storage c, bool hit, uint80 proofRoundId, bool forced) private {
        c.status = hit ? Status.Hit : Status.Miss;
        c.proofRoundId = proofRoundId;
        c.forced = forced;
        c.settledAt = uint64(block.timestamp);

        Stats storage s = _stats[c.caller];
        if (hit) {
            ++s.hits;
            ++s.currentStreak;
            if (s.currentStreak > s.bestStreak) s.bestStreak = s.currentStreak;
        } else {
            ++s.misses;
            s.currentStreak = 0;
        }
        emit Settled(id, c.caller, hit, proofRoundId, forced);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice A caller's full record in one read.
    function getStats(address caller) external view returns (Stats memory) {
        return _stats[caller];
    }

    function getCall(uint256 id) external view returns (Call memory) {
        return _calls[id];
    }

    /// @notice Every feed ever listed, enabled or not.
    function feeds() external view returns (address[] memory) {
        return _feeds;
    }

    /// @notice Decimals of a feed, i.e. the scale target prices must use.
    function feedDecimals(address feed) external view returns (uint8) {
        return AggregatorV3Interface(feed).decimals();
    }

    /// @notice Helper mirroring the commit hash computation.
    function hashCall(
        address caller,
        address feed,
        Direction direction,
        int256 targetPrice,
        uint64 expiry,
        bytes32 salt
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(caller, feed, direction, targetPrice, expiry, salt));
    }
}
