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
  }) => throw UnimplementedError();
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
