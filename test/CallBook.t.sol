// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CallBook} from "../src/CallBook.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract CallBookTest is Test {
    CallBook internal book;
    MockAggregatorV3 internal eth;
    MockAggregatorV3 internal btc;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant T0 = 1_800_000_000;
    int256 internal constant ETH_PRICE = 2_000e8;
    int256 internal constant BTC_PRICE = 60_000e8;
    bytes32 internal constant SALT = keccak256("salt");

    event Committed(uint256 indexed id, address indexed caller, bytes32 commitHash, uint64 committedAt, uint64 expiry);
    event Revealed(
        uint256 indexed id,
        address indexed caller,
        address indexed feed,
        CallBook.Direction direction,
        int256 targetPrice,
        int256 commitPrice
    );
    event Settled(uint256 indexed id, address indexed caller, bool hit, uint80 proofRoundId, bool forced);

    function setUp() public {
        vm.warp(T0);
        eth = new MockAggregatorV3(8);
        btc = new MockAggregatorV3(8);
        eth.pushRound(ETH_PRICE, T0 - 10 minutes);
        btc.pushRound(BTC_PRICE, T0 - 10 minutes);
        book = new CallBook(owner, address(eth), address(btc));
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _hash(address caller, address feed, CallBook.Direction dir, int256 target, uint64 expiry, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(caller, feed, dir, target, expiry, salt));
    }

    function _commit(address caller, address feed, CallBook.Direction dir, int256 target, uint64 expiry)
        internal
        returns (uint256 id)
    {
        vm.prank(caller);
        id = book.commit(_hash(caller, feed, dir, target, expiry, SALT), expiry);
    }

    function _expiry(uint256 duration) internal view returns (uint64) {
        return uint64(block.timestamp + duration);
    }

    // ------------------------------------------------------------------
    // Construction and feed management
    // ------------------------------------------------------------------

    function test_constructor_listsAndEnablesFeeds() public view {
        address[] memory f = book.feeds();
        assertEq(f.length, 2);
        assertEq(f[0], address(eth));
        assertEq(f[1], address(btc));
        assertTrue(book.feedEnabled(address(eth)));
        assertTrue(book.feedEnabled(address(btc)));
        assertEq(book.owner(), owner);
        assertEq(book.feedDecimals(address(eth)), 8);
    }

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(CallBook.ZeroAddress.selector);
        new CallBook(address(0), address(eth), address(btc));
        vm.expectRevert(CallBook.ZeroAddress.selector);
        new CallBook(owner, address(0), address(btc));
    }

    function test_owner_canAddAndDisableFeeds() public {
        MockAggregatorV3 link = new MockAggregatorV3(8);
        vm.prank(owner);
        book.addFeed(address(link));
        assertTrue(book.feedEnabled(address(link)));
        assertEq(book.feeds().length, 3);

        vm.prank(owner);
        book.disableFeed(address(link));
        assertFalse(book.feedEnabled(address(link)));
        assertTrue(book.isListed(address(link)));

        // Re-enabling does not list it twice.
        vm.prank(owner);
        book.addFeed(address(link));
        assertTrue(book.feedEnabled(address(link)));
        assertEq(book.feeds().length, 3);
    }

    function test_owner_disableRevertsWhenNotEnabled() public {
        vm.prank(owner);
        book.disableFeed(address(eth));
        vm.prank(owner);
        vm.expectRevert(CallBook.FeedNotEnabled.selector);
        book.disableFeed(address(eth));
    }

    function test_nonOwner_cannotManageFeeds() public {
        vm.prank(alice);
        vm.expectRevert(CallBook.NotOwner.selector);
        book.addFeed(address(eth));
        vm.prank(alice);
        vm.expectRevert(CallBook.NotOwner.selector);
        book.disableFeed(address(eth));
    }

    function test_addFeed_rejectsNonAggregator() public {
        vm.prank(owner);
        vm.expectRevert();
        book.addFeed(alice);
    }

    function test_addFeed_boundedByMaxFeeds() public {
        for (uint256 i = 2; i < book.MAX_FEEDS(); ++i) {
            address extra = address(new MockAggregatorV3(8));
            vm.prank(owner);
            book.addFeed(extra);
        }
        address oneTooMany = address(new MockAggregatorV3(8));
        vm.prank(owner);
        vm.expectRevert(CallBook.TooManyFeeds.selector);
        book.addFeed(oneTooMany);
    }

    function test_contract_holdsNoEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(book).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(book).balance, 0);
    }

    // ------------------------------------------------------------------
    // Commit
    // ------------------------------------------------------------------

    function test_commit_recordsPricesStatsAndEvent() public {
        uint64 expiry = _expiry(1 days);
        bytes32 h = _hash(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry, SALT);

        vm.expectEmit(true, true, true, true);
        emit Committed(1, alice, h, uint64(T0), expiry);
        vm.prank(alice);
        uint256 id = book.commit(h, expiry);

        assertEq(id, 1);
        assertEq(book.callCount(), 1);
        assertEq(book.commitPriceOf(id, address(eth)), ETH_PRICE);
        assertEq(book.commitPriceOf(id, address(btc)), BTC_PRICE);

        CallBook.Call memory c = book.getCall(id);
        assertEq(c.caller, alice);
        assertEq(c.committedAt, uint64(T0));
        assertEq(c.expiry, expiry);
        assertEq(uint8(c.status), uint8(CallBook.Status.Committed));
        assertEq(c.commitHash, h);

        CallBook.Stats memory s = book.getStats(alice);
        assertEq(s.calls, 1);
        assertEq(s.hits, 0);
        assertEq(s.misses, 0);
    }

    function test_commit_rejectsEmptyHash() public {
        vm.prank(alice);
        vm.expectRevert(CallBook.EmptyHash.selector);
        book.commit(bytes32(0), _expiry(1 days));
    }

    function test_commit_expiryBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(CallBook.BadExpiry.selector);
        book.commit(bytes32(uint256(1)), _expiry(1 hours - 1));
        vm.expectRevert(CallBook.BadExpiry.selector);
        book.commit(bytes32(uint256(1)), _expiry(30 days + 1));
        book.commit(bytes32(uint256(1)), _expiry(1 hours));
        book.commit(bytes32(uint256(1)), _expiry(30 days));
        vm.stopPrank();
        assertEq(book.callCount(), 2);
    }

    function test_commit_rejectsStaleFeed() public {
        eth.pushRound(ETH_PRICE, block.timestamp - book.MAX_PRICE_AGE() - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallBook.StalePrice.selector, address(eth)));
        book.commit(bytes32(uint256(1)), _expiry(1 days));
    }

    function test_commit_rejectsIncompleteLatestRound() public {
        // answeredInRound behind roundId: the answer is carried over from an older round.
        btc.setRound(9, BTC_PRICE, block.timestamp, block.timestamp, 8);
        btc.setLatest(9);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallBook.StalePrice.selector, address(btc)));
        book.commit(bytes32(uint256(1)), _expiry(1 days));

        // updatedAt == 0: round not finished.
        btc.setRound(10, BTC_PRICE, block.timestamp, 0, 10);
        btc.setLatest(10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CallBook.StalePrice.selector, address(btc)));
        book.commit(bytes32(uint256(1)), _expiry(1 days));
    }

    function test_commit_rejectsNonPositiveAnswer() public {
        eth.pushRound(0, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(CallBook.BadAnswer.selector);
        book.commit(bytes32(uint256(1)), _expiry(1 days));
    }

    function test_commit_skipsDisabledFeedAndNeedsAtLeastOne() public {
        vm.prank(owner);
        book.disableFeed(address(btc));
        // BTC stale now, but disabled feeds are not read.
        btc.pushRound(BTC_PRICE, block.timestamp - 10 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, _expiry(1 days));
        assertEq(book.commitPriceOf(id, address(btc)), 0);
        assertEq(book.commitPriceOf(id, address(eth)), ETH_PRICE);

        vm.prank(owner);
        book.disableFeed(address(eth));
        vm.prank(alice);
        vm.expectRevert(CallBook.NoFeeds.selector);
        book.commit(bytes32(uint256(1)), _expiry(1 days));
    }

    // ------------------------------------------------------------------
    // Reveal
    // ------------------------------------------------------------------

    function test_reveal_happyPath() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);

        vm.expectEmit(true, true, true, true);
        emit Revealed(id, alice, address(eth), CallBook.Direction.UP, 2_500e8, ETH_PRICE);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        CallBook.Call memory c = book.getCall(id);
        assertEq(uint8(c.status), uint8(CallBook.Status.Revealed));
        assertEq(c.feed, address(eth));
        assertEq(c.targetPrice, 2_500e8);
        assertEq(c.commitPrice, ETH_PRICE);
    }

    function test_reveal_wrongCaller() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);
        vm.prank(bob);
        vm.expectRevert(CallBook.NotCaller.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
    }

    function test_reveal_beforeExpiry() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry - 1);
        vm.prank(alice);
        vm.expectRevert(CallBook.NotExpired.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
    }

    function test_reveal_late() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(uint256(expiry) + book.REVEAL_WINDOW() + 1);
        vm.prank(alice);
        vm.expectRevert(CallBook.RevealWindowClosed.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        // Exactly at the end of the window is still allowed.
        vm.warp(uint256(expiry) + book.REVEAL_WINDOW());
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
    }

    function test_reveal_hashMismatch() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);
        vm.startPrank(alice);
        vm.expectRevert(CallBook.HashMismatch.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, keccak256("other"));
        vm.expectRevert(CallBook.HashMismatch.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_400e8, SALT);
        vm.expectRevert(CallBook.HashMismatch.selector);
        book.reveal(id, address(eth), CallBook.Direction.DOWN, 2_500e8, SALT);
        vm.expectRevert(CallBook.HashMismatch.selector);
        book.reveal(id, address(btc), CallBook.Direction.UP, 2_500e8, SALT);
        vm.stopPrank();
    }

    function test_reveal_unknownOrSettledCall() public {
        vm.prank(alice);
        vm.expectRevert(CallBook.NotCommitted.selector);
        book.reveal(42, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);
        vm.startPrank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
        vm.expectRevert(CallBook.NotCommitted.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
        vm.stopPrank();
    }

    function test_reveal_targetMustBeOnCorrectSide() public {
        uint64 expiry = _expiry(1 days);
        uint256 upId = _commit(alice, address(eth), CallBook.Direction.UP, ETH_PRICE, expiry);
        uint256 downId = _commit(alice, address(eth), CallBook.Direction.DOWN, ETH_PRICE + 1, expiry);
        uint256 negId = _commit(alice, address(eth), CallBook.Direction.DOWN, -1, expiry);
        vm.warp(expiry);
        vm.startPrank(alice);
        vm.expectRevert(CallBook.TargetWrongSide.selector);
        book.reveal(upId, address(eth), CallBook.Direction.UP, ETH_PRICE, SALT);
        vm.expectRevert(CallBook.TargetWrongSide.selector);
        book.reveal(downId, address(eth), CallBook.Direction.DOWN, ETH_PRICE + 1, SALT);
        vm.expectRevert(CallBook.BadTarget.selector);
        book.reveal(negId, address(eth), CallBook.Direction.DOWN, -1, SALT);
        vm.stopPrank();
    }

    function test_reveal_feedNotRecordedAtCommit() public {
        MockAggregatorV3 link = new MockAggregatorV3(8);
        link.pushRound(15e8, block.timestamp);
        uint64 expiry = _expiry(1 days);
        // Committed against a feed the book did not have enabled at commit time.
        uint256 id = _commit(alice, address(link), CallBook.Direction.UP, 20e8, expiry);
        vm.prank(owner);
        book.addFeed(address(link));
        vm.warp(expiry);
        vm.prank(alice);
        vm.expectRevert(CallBook.FeedNotRecorded.selector);
        book.reveal(id, address(link), CallBook.Direction.UP, 20e8, SALT);
    }

    function test_reveal_andSettleStillWorkAfterFeedDisabled() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(btc), CallBook.Direction.DOWN, 55_000e8, expiry);
        vm.prank(owner);
        book.disableFeed(address(btc));
        uint80 proof = btc.pushRound(54_000e8, T0 + 12 hours);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(btc), CallBook.Direction.DOWN, 55_000e8, SALT);
        vm.prank(keeper);
        book.settle(id, proof);
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Hit));
    }

    // ------------------------------------------------------------------
    // Settle
    // ------------------------------------------------------------------

    function test_settle_hitProvenByIntermediateRound() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        eth.pushRound(2_200e8, T0 + 6 hours);
        uint80 spike = eth.pushRound(2_600e8, T0 + 12 hours);
        uint80 last = eth.pushRound(2_100e8, T0 + 23 hours);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        // The final round did not reach the target; it is not a proof.
        vm.prank(keeper);
        vm.expectRevert(CallBook.NotAHit.selector);
        book.settle(id, last);

        vm.expectEmit(true, true, true, true);
        emit Settled(id, alice, true, spike, false);
        vm.prank(keeper);
        book.settle(id, spike);

        CallBook.Call memory c = book.getCall(id);
        assertEq(uint8(c.status), uint8(CallBook.Status.Hit));
        assertEq(c.proofRoundId, spike);
        assertFalse(c.forced);
        CallBook.Stats memory s = book.getStats(alice);
        assertEq(s.calls, 1);
        assertEq(s.hits, 1);
        assertEq(s.misses, 0);
        assertEq(s.currentStreak, 1);
        assertEq(s.bestStreak, 1);
    }

    function test_settle_hitAtExactTargetAndBoundaries() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.DOWN, 1_900e8, expiry);
        // Round exactly at expiry with the answer exactly at target counts.
        uint80 proof = eth.pushRound(1_900e8, expiry);
        vm.warp(expiry);
        vm.prank(alice);
        book.revealAndSettle(id, address(eth), CallBook.Direction.DOWN, 1_900e8, SALT, proof);
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Hit));

        // Round exactly at commit time also counts. Refresh BTC so the second commit's snapshot is not stale.
        btc.pushRound(BTC_PRICE, block.timestamp);
        uint256 id2 = _commit(bob, address(eth), CallBook.Direction.UP, 1_950e8, _expiry(1 days));
        uint80 proof2 = eth.pushRound(2_000e8, block.timestamp);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bob);
        book.revealAndSettle(id2, address(eth), CallBook.Direction.UP, 1_950e8, SALT, proof2);
        assertEq(uint8(book.getCall(id2).status), uint8(CallBook.Status.Hit));
    }

    function test_settle_missWithoutProof_byCaller() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);
        vm.startPrank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
        vm.expectEmit(true, true, true, true);
        emit Settled(id, alice, false, 0, false);
        book.settle(id, 0);
        vm.stopPrank();

        CallBook.Stats memory s = book.getStats(alice);
        assertEq(s.misses, 1);
        assertEq(s.hits, 0);
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Miss));
    }

    function test_settle_thirdPartyMissOnlyAfterRevealWindow() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        // A griefer cannot front-run the caller's proof with a premature MISS.
        vm.prank(bob);
        vm.expectRevert(CallBook.RevealWindowOpen.selector);
        book.settle(id, 0);

        vm.warp(uint256(expiry) + book.REVEAL_WINDOW() + 1);
        vm.prank(bob);
        book.settle(id, 0);
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Miss));
    }

    function test_settle_hitProofAcceptedAfterRevealWindow() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        uint80 spike = eth.pushRound(2_600e8, T0 + 12 hours);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
        vm.warp(uint256(expiry) + 10 days);
        vm.prank(keeper);
        book.settle(id, spike);
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Hit));
    }

    function test_settle_rejectsRoundsOutsideWindow() public {
        uint80 before = eth.latestRound(); // updatedAt = T0 - 10 minutes
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.DOWN, 1_500e8, expiry);
        eth.setRound(before, 1_000e8, T0 - 10 minutes, T0 - 10 minutes, before);
        uint80 after_ = eth.pushRound(1_000e8, uint256(expiry) + 1);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.DOWN, 1_500e8, SALT);

        vm.expectRevert(CallBook.RoundOutsideWindow.selector);
        book.settle(id, before);
        vm.expectRevert(CallBook.RoundOutsideWindow.selector);
        book.settle(id, after_);
    }

    function test_settle_rejectsStaleAndIncompleteRounds() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        // Stale: answeredInRound behind the round id.
        eth.setRound(50, 3_000e8, T0 + 1 hours, T0 + 1 hours, 49);
        // Incomplete: never updated.
        eth.setRound(51, 3_000e8, T0 + 1 hours, 0, 51);
        // Non-positive answer inside the window.
        eth.setRound(52, 0, T0 + 1 hours, T0 + 1 hours, 52);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        vm.expectRevert(CallBook.IncompleteRound.selector);
        book.settle(id, 50);
        vm.expectRevert(CallBook.IncompleteRound.selector);
        book.settle(id, 51);
        vm.expectRevert(CallBook.BadAnswer.selector);
        book.settle(id, 52);
        // Nonexistent round: the aggregator itself reverts.
        vm.expectRevert(bytes("No data present"));
        book.settle(id, 999);
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Revealed));
    }

    function test_settle_requiresRevealedAndSettlesOnce() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.expectRevert(CallBook.NotRevealed.selector);
        book.settle(id, 0);

        uint80 spike = eth.pushRound(2_600e8, T0 + 12 hours);
        vm.warp(expiry);
        vm.prank(alice);
        book.revealAndSettle(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT, spike);

        vm.expectRevert(CallBook.NotRevealed.selector);
        book.settle(id, spike);
        vm.prank(alice);
        vm.expectRevert(CallBook.NotRevealed.selector);
        book.settle(id, 0);
        vm.expectRevert(CallBook.NotCommitted.selector);
        book.markUnrevealed(id);
    }

    // ------------------------------------------------------------------
    // Forced miss
    // ------------------------------------------------------------------

    function test_markUnrevealed_forcesMissAfterWindow() public {
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);

        vm.warp(uint256(expiry) + book.REVEAL_WINDOW());
        vm.prank(keeper);
        vm.expectRevert(CallBook.RevealWindowOpen.selector);
        book.markUnrevealed(id);

        vm.warp(uint256(expiry) + book.REVEAL_WINDOW() + 1);
        vm.expectEmit(true, true, true, true);
        emit Settled(id, alice, false, 0, true);
        vm.prank(keeper);
        book.markUnrevealed(id);

        CallBook.Call memory c = book.getCall(id);
        assertEq(uint8(c.status), uint8(CallBook.Status.Miss));
        assertTrue(c.forced);
        CallBook.Stats memory s = book.getStats(alice);
        assertEq(s.misses, 1);
        assertEq(s.currentStreak, 0);

        // The caller can no longer reveal it.
        vm.prank(alice);
        vm.expectRevert(CallBook.NotCommitted.selector);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
    }

    function test_markUnrevealed_rejectsRevealedOrUnknown() public {
        vm.expectRevert(CallBook.NotCommitted.selector);
        book.markUnrevealed(7);
        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);
        vm.warp(uint256(expiry) + 2 days);
        vm.expectRevert(CallBook.NotCommitted.selector);
        book.markUnrevealed(id);
    }

    // ------------------------------------------------------------------
    // Stats and streaks
    // ------------------------------------------------------------------

    function test_stats_streaksFollowSettlementOrder() public {
        uint64 expiry = _expiry(1 days);
        uint256 a = _commit(alice, address(eth), CallBook.Direction.UP, 2_100e8, expiry);
        uint256 b = _commit(alice, address(eth), CallBook.Direction.UP, 2_200e8, expiry);
        uint256 c = _commit(alice, address(eth), CallBook.Direction.UP, 9_000e8, expiry);
        uint256 d = _commit(alice, address(eth), CallBook.Direction.DOWN, 1_900e8, expiry);
        uint256 e = _commit(alice, address(eth), CallBook.Direction.UP, 9_500e8, expiry);
        uint80 up = eth.pushRound(2_300e8, T0 + 2 hours);
        uint80 down = eth.pushRound(1_800e8, T0 + 4 hours);
        vm.warp(expiry);

        vm.startPrank(alice);
        book.revealAndSettle(a, address(eth), CallBook.Direction.UP, 2_100e8, SALT, up);
        book.revealAndSettle(b, address(eth), CallBook.Direction.UP, 2_200e8, SALT, up);
        book.revealAndSettle(c, address(eth), CallBook.Direction.UP, 9_000e8, SALT, 0);
        book.revealAndSettle(d, address(eth), CallBook.Direction.DOWN, 1_900e8, SALT, down);
        vm.stopPrank();
        // e is never revealed.
        vm.warp(uint256(expiry) + book.REVEAL_WINDOW() + 1);
        book.markUnrevealed(e);

        CallBook.Stats memory s = book.getStats(alice);
        assertEq(s.calls, 5);
        assertEq(s.hits, 3);
        assertEq(s.misses, 2);
        assertEq(s.currentStreak, 0);
        assertEq(s.bestStreak, 2);
        // Bob's record is untouched.
        CallBook.Stats memory sb = book.getStats(bob);
        assertEq(sb.calls, 0);
    }

    // ------------------------------------------------------------------
    // Feed decimals
    // ------------------------------------------------------------------

    function test_feedDecimals_targetsUseTheFeedScale() public {
        MockAggregatorV3 link = new MockAggregatorV3(18);
        link.pushRound(15e18, block.timestamp);
        vm.prank(owner);
        book.addFeed(address(link));
        assertEq(book.feedDecimals(address(link)), 18);

        uint64 expiry = _expiry(2 days);
        // 20 "dollars" expressed with 18 decimals; an 8-decimal target (20e8) would be far below the
        // 18-decimal commit price and rejected as being on the wrong side.
        uint256 id = _commit(alice, address(link), CallBook.Direction.UP, 20e18, expiry);
        uint256 wrongScale = _commit(alice, address(link), CallBook.Direction.UP, 20e8, expiry);
        uint80 proof = link.pushRound(21e18, T0 + 1 days);
        vm.warp(expiry);
        vm.startPrank(alice);
        book.revealAndSettle(id, address(link), CallBook.Direction.UP, 20e18, SALT, proof);
        vm.expectRevert(CallBook.TargetWrongSide.selector);
        book.reveal(wrongScale, address(link), CallBook.Direction.UP, 20e8, SALT);
        vm.stopPrank();
        assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Hit));
    }

    function test_hashCall_matchesOffchainEncoding() public view {
        bytes32 expected = _hash(alice, address(eth), CallBook.Direction.DOWN, 1_234e8, 123456, SALT);
        assertEq(book.hashCall(alice, address(eth), CallBook.Direction.DOWN, 1_234e8, 123456, SALT), expected);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_commit_expiryWindow(uint64 duration) public {
        uint64 expiry = uint64(bound(duration, 0, 60 days)) + uint64(block.timestamp);
        bool ok = expiry >= block.timestamp + book.MIN_DURATION() && expiry <= block.timestamp + book.MAX_DURATION();
        vm.prank(alice);
        if (!ok) vm.expectRevert(CallBook.BadExpiry.selector);
        book.commit(bytes32(uint256(1)), expiry);
        assertEq(book.callCount(), ok ? 1 : 0);
    }

    function testFuzz_settle_upHitIffAnswerReachesTarget(int256 commitPrice, int256 target, int256 answer) public {
        commitPrice = bound(commitPrice, 1, type(int128).max - 1);
        target = bound(target, commitPrice + 1, type(int128).max);
        answer = bound(answer, 1, type(int128).max);
        eth.pushRound(commitPrice, block.timestamp);

        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, target, expiry);
        uint80 proof = eth.pushRound(answer, T0 + 1 hours);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, target, SALT);

        if (answer >= target) {
            book.settle(id, proof);
            assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Hit));
        } else {
            vm.expectRevert(CallBook.NotAHit.selector);
            book.settle(id, proof);
        }
    }

    function testFuzz_settle_downHitIffAnswerReachesTarget(int256 commitPrice, int256 target, int256 answer) public {
        commitPrice = bound(commitPrice, 2, type(int128).max);
        target = bound(target, 1, commitPrice - 1);
        answer = bound(answer, 1, type(int128).max);
        eth.pushRound(commitPrice, block.timestamp);

        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.DOWN, target, expiry);
        uint80 proof = eth.pushRound(answer, T0 + 1 hours);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.DOWN, target, SALT);

        if (answer <= target) {
            book.settle(id, proof);
            assertEq(uint8(book.getCall(id).status), uint8(CallBook.Status.Hit));
        } else {
            vm.expectRevert(CallBook.NotAHit.selector);
            book.settle(id, proof);
        }
    }

    function testFuzz_reveal_targetSideCheck(int256 commitPrice, int256 target, bool up) public {
        commitPrice = bound(commitPrice, 1, type(int128).max);
        target = bound(target, 1, type(int128).max);
        eth.pushRound(commitPrice, block.timestamp);
        CallBook.Direction dir = up ? CallBook.Direction.UP : CallBook.Direction.DOWN;

        uint64 expiry = _expiry(1 days);
        uint256 id = _commit(alice, address(eth), dir, target, expiry);
        vm.warp(expiry);
        bool valid = up ? target > commitPrice : target < commitPrice;
        vm.prank(alice);
        if (!valid) vm.expectRevert(CallBook.TargetWrongSide.selector);
        book.reveal(id, address(eth), dir, target, SALT);
    }

    function testFuzz_settle_roundTimestampWindow(uint256 updatedAt) public {
        uint64 expiry = _expiry(7 days);
        updatedAt = bound(updatedAt, T0 - 1 days, uint256(expiry) + 1 days);
        uint256 id = _commit(alice, address(eth), CallBook.Direction.UP, 2_500e8, expiry);
        uint80 proof = eth.pushRound(3_000e8, updatedAt);
        vm.warp(expiry);
        vm.prank(alice);
        book.reveal(id, address(eth), CallBook.Direction.UP, 2_500e8, SALT);

        bool inWindow = updatedAt >= T0 && updatedAt <= expiry;
        if (!inWindow) vm.expectRevert(CallBook.RoundOutsideWindow.selector);
        book.settle(id, proof);
    }
}
