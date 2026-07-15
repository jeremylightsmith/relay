import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/decisions/review_queue.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'support/fake_auth.dart';

FeedRow row(String ref, {String kind = 'in_review', String slug = 'relay'}) =>
    FeedRow(
      ref: ref,
      title: 'Card $ref',
      board: FeedBoard(name: 'Relay', key: 'RLY', slug: slug),
      status: kind,
      kind: kind,
      reason: 'Review',
      blockedAt: DateTime.utc(2026, 7, 15),
    );

FeedPage page(List<FeedRow> rows) => FeedPage(
  rows: rows,
  meta: FeedMeta(count: rows.length),
);

class FakeDecisionApi implements DecisionApi {
  FakeDecisionApi([this.result = const DecisionOk({})]);

  DecisionResult result;
  final List<String> approved = [];
  final List<String> rejected = [];

  /// Parallel to [rejected] — the note and board slug that ref actually carried,
  /// so callers can catch plumbing bugs (a dropped controller read, a typo'd
  /// query param) that a bare ref list would miss.
  final List<String> rejectedNotes = [];
  final List<String> rejectedBoards = [];

  @override
  Future<DecisionResult> approve({
    required String ref,
    required String boardSlug,
  }) async {
    approved.add(ref);
    return result;
  }

  @override
  Future<DecisionResult> reject({
    required String ref,
    required String boardSlug,
    required String note,
  }) async {
    rejected.add(ref);
    rejectedNotes.add(note);
    rejectedBoards.add(boardSlug);
    return result;
  }
}

/// Never answers until the test says so — the only way to observe an in-flight decision.
class BlockedDecisionApi implements DecisionApi {
  final completer = Completer<DecisionResult>();
  int calls = 0;

  @override
  Future<DecisionResult> approve({
    required String ref,
    required String boardSlug,
  }) {
    calls++;
    return completer.future;
  }

  @override
  Future<DecisionResult> reject({
    required String ref,
    required String boardSlug,
    required String note,
  }) {
    calls++;
    return completer.future;
  }
}

class FakeFeedRepository implements FeedRepository {
  FakeFeedRepository([this.pages = const []]);

  final List<FeedPage> pages;
  int calls = 0;

  @override
  Future<FeedPage> fetchFeed() async {
    calls++;
    return pages.length >= calls ? pages[calls - 1] : page(const []);
  }
}

({ProviderContainer container, FakeAuthController auth}) harness({
  required DecisionApi api,
  FeedRepository? feed,
}) {
  final auth = FakeAuthController(
    const AuthState(status: AuthStatus.signedIn, token: 'relayu_t'),
  );
  final container = ProviderContainer(
    overrides: [
      decisionApiProvider.overrideWithValue(api),
      feedRepositoryProvider.overrideWithValue(feed ?? FakeFeedRepository()),
      authProvider.overrideWith(() => auth),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, auth: auth);
}

void main() {
  test('enter snapshots the feed order and starts at the tapped ref', () {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);

    queue.enter(
      rows: [row('RLY-A'), row('RLY-B'), row('RLY-C')],
      atRef: 'RLY-B',
    );

    final state = h.container.read(reviewQueueProvider);
    expect(state.items.map((i) => i.ref), ['RLY-A', 'RLY-B', 'RLY-C']);
    expect(state.index, 1);
    expect(state.current!.ref, 'RLY-B');
    expect(state.current!.boardSlug, 'relay');
  });

  test('an unknown atRef starts at the top rather than off the end', () {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);

    queue.enter(rows: [row('RLY-A')], atRef: 'RLY-GONE');

    expect(h.container.read(reviewQueueProvider).index, 0);
  });

  test(
    'approving advances to the next snapshot item and banners the ref',
    () async {
      final h = harness(api: FakeDecisionApi());
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final dest = await queue.approveCurrent();

      expect(dest, '/card/RLY-B?kind=in_review');
      expect(h.container.read(reviewQueueProvider).banner, 'Approved · RLY-A');
    },
  );

  test(
    'the snapshot holds its order even though the feed would reorder under us',
    () async {
      // RLY-C blocked mid-walk would sort to the top of a refetch. We must not see it.
      final feed = FakeFeedRepository([
        page([row('RLY-C'), row('RLY-B')]),
      ]);
      final h = harness(api: FakeDecisionApi(), feed: feed);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final dest = await queue.approveCurrent();

      expect(dest, '/card/RLY-B?kind=in_review');
      expect(
        feed.calls,
        0,
        reason: 'no refetch mid-snapshot — that is the whole point',
      );
    },
  );

  test('a 422 not_in_review is skipped, not errored', () async {
    final h = harness(
      api: FakeDecisionApi(
        const DecisionFailed(
          'not_in_review',
          'This card is not in a review stage',
        ),
      ),
    );
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

    final dest = await queue.approveCurrent();

    expect(dest, '/card/RLY-B?kind=in_review');
    expect(
      h.container.read(reviewQueueProvider).banner,
      'Already handled · RLY-A',
    );
    expect(h.container.read(reviewQueueProvider).error, isNull);
  });

  test('the end of the snapshot refetches once and keeps going', () async {
    final feed = FakeFeedRepository([
      page([row('RLY-D'), row('RLY-E')]),
    ]);
    final h = harness(api: FakeDecisionApi(), feed: feed);
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');

    final dest = await queue.approveCurrent();

    expect(feed.calls, 1);
    expect(dest, '/card/RLY-D?kind=in_review');
    final state = h.container.read(reviewQueueProvider);
    expect(state.items.map((i) => i.ref), ['RLY-D', 'RLY-E']);
    expect(state.index, 0);
  });

  test(
    'the end of the snapshot with nothing fresh lands on the inbox',
    () async {
      final h = harness(api: FakeDecisionApi(), feed: FakeFeedRepository());
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');

      final dest = await queue.approveCurrent();

      expect(dest, '/needs-you');
      expect(h.container.read(reviewQueueProvider).banner, 'Approved · RLY-A');
    },
  );

  test(
    'a second approve during an in-flight decision issues no second POST',
    () async {
      final api = BlockedDecisionApi();
      final h = harness(api: api);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final first = queue.approveCurrent();
      final second = await queue.approveCurrent(); // the double-tap

      expect(api.calls, 1);
      expect(second, isNull, reason: 'the second tap must not navigate either');

      api.completer.complete(const DecisionOk({}));
      expect(await first, '/card/RLY-B?kind=in_review');
      expect(h.container.read(reviewQueueProvider).inFlight, isFalse);
    },
  );

  test('a network failure stays put and surfaces the message', () async {
    final h = harness(
      api: FakeDecisionApi(
        const DecisionFailed(
          'network',
          'Network error — could not reach Relay.',
        ),
      ),
    );
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

    final dest = await queue.approveCurrent();

    expect(
      dest,
      isNull,
      reason: 'a failed decision must never advance the queue',
    );
    final state = h.container.read(reviewQueueProvider);
    expect(state.index, 0);
    expect(state.error, 'Network error — could not reach Relay.');
    expect(state.banner, isNull);
  });

  test(
    'an ambiguous_ref surfaces the server message verbatim and does not advance',
    () async {
      final h = harness(
        api: FakeDecisionApi(
          const DecisionFailed(
            'ambiguous_ref',
            'That ref matches cards on more than one of your boards — pass board: <slug>',
          ),
        ),
      );
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      expect(await queue.approveCurrent(), isNull);
      expect(
        h.container.read(reviewQueueProvider).error,
        'That ref matches cards on more than one of your boards — pass board: <slug>',
      );
    },
  );

  test('a 401 signs out — the router does the rest', () async {
    final h = harness(
      api: FakeDecisionApi(
        const DecisionFailed('unauthorized', 'Invalid or missing user token'),
      ),
    );
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');

    expect(await queue.approveCurrent(), isNull);
    expect(h.auth.signOutCalls, 1);
  });

  test(
    'rejecting posts the note and board slug and advances, bannering the ref',
    () async {
      final api = FakeDecisionApi();
      final h = harness(api: api);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final dest = await queue.rejectCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
        note: 'Needs error handling',
      );

      expect(dest, '/card/RLY-B?kind=in_review');
      expect(api.rejected, ['RLY-A']);
      expect(api.rejectedNotes, ['Needs error handling']);
      expect(api.rejectedBoards, ['relay']);
      expect(h.container.read(reviewQueueProvider).banner, 'Sent back · RLY-A');
    },
  );

  test(
    'rejecting with a ref the queue is not sitting on errors instead of '
    'silently no-opping — the route is not the authority, the snapshot is',
    () async {
      final h = harness(api: FakeDecisionApi());
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final dest = await queue.rejectCurrent(
        cardRef: 'RLY-B', // the queue is sitting on RLY-A
        boardSlug: 'relay',
        note: 'Wrong card',
      );

      expect(dest, isNull);
      expect(
        h.container.read(reviewQueueProvider).error,
        isNotNull,
        reason: 'a mismatch must surface, not silently do nothing',
      );
      expect(
        h.container.read(reviewQueueProvider).index,
        0,
        reason: 'must not touch the snapshot cursor',
      );
    },
  );

  test('rejecting a board slug the queue disagrees with errors the same way '
      '(refs are only unique within a board)', () async {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(
      rows: [row('RLY-A', slug: 'relay')],
      atRef: 'RLY-A',
    );

    final dest = await queue.rejectCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'other-board',
      note: 'Wrong board',
    );

    expect(dest, isNull);
    expect(h.container.read(reviewQueueProvider).error, isNotNull);
  });

  test('rejecting against an empty queue (a genuine cold deep link) errors '
      'instead of returning null with no signal', () async {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);
    // No `enter()` — this is what a cold deep link's queue looks like.

    final dest = await queue.rejectCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
      note: 'Needs error handling',
    );

    expect(dest, isNull);
    expect(h.container.read(reviewQueueProvider).error, isNotNull);
  });

  test(
    'rejecting into a 422 not_in_review is "already handled", same as approve',
    () async {
      final h = harness(
        api: FakeDecisionApi(
          const DecisionFailed(
            'not_in_review',
            'This card is not in a review stage',
          ),
        ),
      );
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final dest = await queue.rejectCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
        note: 'Please revise',
      );

      expect(dest, '/card/RLY-B?kind=in_review');
      expect(
        h.container.read(reviewQueueProvider).banner,
        'Already handled · RLY-A',
      );
      expect(h.container.read(reviewQueueProvider).error, isNull);
    },
  );

  test('rejecting on a 401 signs out — the router does the rest', () async {
    final h = harness(
      api: FakeDecisionApi(
        const DecisionFailed('unauthorized', 'Invalid or missing user token'),
      ),
    );
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');

    expect(
      await queue.rejectCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
        note: 'Please revise',
      ),
      isNull,
    );
    expect(h.auth.signOutCalls, 1);
  });

  test(
    'a second reject during an in-flight decision issues no second POST',
    () async {
      final api = BlockedDecisionApi();
      final h = harness(api: api);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final first = queue.rejectCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
        note: 'first',
      );
      final second = await queue.rejectCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
        note: 'second',
      ); // the double-tap

      expect(api.calls, 1);
      expect(second, isNull, reason: 'the second tap must not navigate either');

      api.completer.complete(const DecisionOk({}));
      expect(await first, '/card/RLY-B?kind=in_review');
      expect(h.container.read(reviewQueueProvider).inFlight, isFalse);
    },
  );

  test('takeBanner hands the banner over exactly once', () async {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
    await queue.approveCurrent();

    expect(queue.takeBanner(), 'Approved · RLY-A');
    expect(
      queue.takeBanner(),
      isNull,
      reason: 'the next screen must not re-show it',
    );
  });
}
