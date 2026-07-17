import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/decisions/review_queue.dart';
import 'package:relay_mobile/features/needs_you/feed_controller.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'support/fake_auth.dart';

FeedRow row(
  String ref, {
  String kind = 'in_review',
  String slug = 'relay',
  String boardName = 'Relay',
  String stage = 'Code',
  String reason = 'Review',
  List<FeedQuestion>? questions,
}) => FeedRow(
  ref: ref,
  title: 'Card $ref',
  board: FeedBoard(name: boardName, key: 'RLY', slug: slug),
  status: kind,
  kind: kind,
  stage: stage,
  reason: reason,
  blockedAt: DateTime.utc(2026, 7, 15),
  questions: questions,
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

  final List<({String ref, List<Map<String, String>>? answers, String? text})>
  answered = [];

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

  @override
  Future<DecisionResult> answer({
    required String ref,
    required String boardSlug,
    List<Map<String, String>>? answers,
    String? text,
  }) async {
    answered.add((ref: ref, answers: answers, text: text));
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

  @override
  Future<DecisionResult> answer({
    required String ref,
    required String boardSlug,
    List<Map<String, String>>? answers,
    String? text,
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

/// First page answers immediately (the inbox's seed); every later call hangs
/// on [pending] — the only way to observe the optimistic removal before the
/// background reconcile lands.
class StagedFeedRepository implements FeedRepository {
  StagedFeedRepository(this.first);

  final FeedPage first;
  final pending = Completer<FeedPage>();
  int calls = 0;

  @override
  Future<FeedPage> fetchFeed() {
    calls++;
    return calls == 1 ? Future.value(first) : pending.future;
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

      final dest = await queue.approveCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
      );

      expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
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

      final dest = await queue.approveCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
      );

      expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
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

    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

    expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
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

    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

    expect(feed.calls, 1);
    expect(dest, '/cards/RLY-D?board=relay&kind=in_review');
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

      final dest = await queue.approveCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
      );

      expect(dest, '/needs-you');
      expect(h.container.read(reviewQueueProvider).banner, 'Approved · RLY-A');
    },
  );

  test(
    'the end-of-snapshot refetch also lands in feedControllerProvider, so the '
    'inbox actually renders caught up rather than staying stale (RLY-89)',
    () async {
      // Only one page queued: the inbox's own initial load. The walk's own
      // end-of-snapshot refetch falls through FakeFeedRepository's default —
      // an empty page — with no second page needed, because it must be served
      // from that *same* refetch rather than firing a request of its own.
      final feed = FakeFeedRepository([
        page([row('RLY-SEED')]),
      ]);
      final h = harness(api: FakeDecisionApi(), feed: feed);

      // Stand in for NeedsYouScreen already having the inbox live, the way it
      // is by the time a human can tap into a queue walk at all.
      await h.container.read(feedControllerProvider.future);
      expect(feed.calls, 1);
      expect(
        h.container.read(feedControllerProvider).value?.rows.map((r) => r.ref),
        ['RLY-SEED'],
      );

      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');

      final dest = await queue.approveCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
      );

      expect(dest, '/needs-you');
      expect(
        feed.calls,
        3,
        reason:
            'the initial load, the D2 background reconcile, and the one '
            'end-of-snapshot refetch — landing on the inbox costs nothing further',
      );
      final inbox = h.container.read(feedControllerProvider).value;
      expect(inbox, isNotNull);
      expect(inbox!.rows, isEmpty);
      expect(inbox.caughtUp, isTrue);
    },
  );

  test(
    'a mid-walk refetch that finds fresh rows also updates feedControllerProvider',
    () async {
      final feed = FakeFeedRepository([
        page([row('RLY-SEED')]),
        // The D2 reconcile consumes this one…
        page([row('RLY-D'), row('RLY-E')]),
        // …and advanceAfter's end-of-snapshot refetch this one.
        page([row('RLY-D'), row('RLY-E')]),
      ]);
      final h = harness(api: FakeDecisionApi(), feed: feed);

      await h.container.read(feedControllerProvider.future);
      expect(feed.calls, 1);

      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');

      final dest = await queue.approveCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
      );

      expect(dest, '/cards/RLY-D?board=relay&kind=in_review');
      expect(feed.calls, 3);
      final inbox = h.container.read(feedControllerProvider).value;
      expect(inbox!.rows.map((r) => r.ref), ['RLY-D', 'RLY-E']);
    },
  );

  test(
    'a second approve during an in-flight decision issues no second POST',
    () async {
      final api = BlockedDecisionApi();
      final h = harness(api: api);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

      final first = queue.approveCurrent(cardRef: 'RLY-A', boardSlug: 'relay');
      final second = await queue.approveCurrent(
        cardRef: 'RLY-A',
        boardSlug: 'relay',
      ); // the double-tap

      expect(api.calls, 1);
      expect(second, isNull, reason: 'the second tap must not navigate either');

      api.completer.complete(const DecisionOk({}));
      expect(await first, '/cards/RLY-B?board=relay&kind=in_review');
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

    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

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

      expect(
        await queue.approveCurrent(cardRef: 'RLY-A', boardSlug: 'relay'),
        isNull,
      );
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

    expect(
      await queue.approveCurrent(cardRef: 'RLY-A', boardSlug: 'relay'),
      isNull,
    );
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

      expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
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

      expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
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
      expect(await first, '/cards/RLY-B?board=relay&kind=in_review');
      expect(h.container.read(reviewQueueProvider).inFlight, isFalse);
    },
  );

  test('takeBanner hands the banner over exactly once', () async {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
    await queue.approveCurrent(cardRef: 'RLY-A', boardSlug: 'relay');

    expect(queue.takeBanner(), 'Approved · RLY-A');
    expect(
      queue.takeBanner(),
      isNull,
      reason: 'the next screen must not re-show it',
    );
  });

  test('a needs_input row carries its questions into the queue', () {
    final h = harness(api: FakeDecisionApi());
    final questions = [
      const FeedQuestion(
        prompt: 'Which region?',
        options: ['us', 'eu'],
        allowText: true,
      ),
    ];

    h.container
        .read(reviewQueueProvider.notifier)
        .enter(
          rows: [
            row(
              'RLY-A',
              kind: 'needs_input',
              questions: questions,
              boardName: 'Data pipeline',
              stage: 'Prep',
            ),
          ],
          atRef: 'RLY-A',
        );

    final current = h.container.read(reviewQueueProvider).current!;
    expect(current.questions, hasLength(1));
    expect(current.questions!.single.prompt, 'Which region?');
    expect(current.boardName, 'Data pipeline');
    expect(current.stage, 'Prep');
  });

  test(
    'routeFor sends needs_input to the answer screen and in_review to the host',
    () {
      expect(
        routeFor(QueueItem.fromRow(row('RLY-A', kind: 'needs_input'))),
        '/card/RLY-A/answer',
      );
      expect(
        routeFor(QueueItem.fromRow(row('RLY-B'))),
        '/cards/RLY-B?board=relay&kind=in_review',
      );
    },
  );

  test(
    'answerCurrent posts the picks and advances with the answer banner',
    () async {
      final api = FakeDecisionApi();
      final h = harness(api: api);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(
        rows: [
          row('RLY-A', kind: 'needs_input'),
          row('RLY-B', kind: 'needs_input'),
        ],
        atRef: 'RLY-A',
      );

      final dest = await queue.answerCurrent(
        answers: [
          {'value': 'eu'},
        ],
      );

      expect(api.answered.single.ref, 'RLY-A');
      expect(api.answered.single.answers, [
        {'value': 'eu'},
      ]);
      expect(dest, '/card/RLY-B/answer');
      expect(queue.takeBanner(), 'Answer sent · RLY-A');
    },
  );

  test('answerCurrent sends free text through for a legacy question', () async {
    final api = FakeDecisionApi();
    final h = harness(api: api);
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(
      rows: [row('RLY-A', kind: 'needs_input')],
      atRef: 'RLY-A',
    );

    await queue.answerCurrent(text: 'eu, please');

    expect(api.answered.single.text, 'eu, please');
    expect(api.answered.single.answers, isNull);
  });

  test('a 422 not_needs_input skips rather than erroring', () async {
    final api = FakeDecisionApi(
      const DecisionFailed(
        'not_needs_input',
        'This card is not waiting on an answer',
      ),
    );
    final h = harness(api: api);
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(
      rows: [
        row('RLY-A', kind: 'needs_input'),
        row('RLY-B', kind: 'needs_input'),
      ],
      atRef: 'RLY-A',
    );

    final dest = await queue.answerCurrent(text: 'eu');

    // Someone answered it on the web while we walked. Not a failure.
    expect(dest, '/card/RLY-B/answer');
    expect(queue.takeBanner(), 'Already handled · RLY-A');
    expect(h.container.read(reviewQueueProvider).error, isNull);
  });

  test(
    'answerCurrent cannot be fired twice while a POST is in flight',
    () async {
      final api = BlockedDecisionApi();
      final h = harness(api: api);
      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(
        rows: [row('RLY-A', kind: 'needs_input')],
        atRef: 'RLY-A',
      );

      final first = queue.answerCurrent(text: 'eu');
      final second = await queue.answerCurrent(text: 'eu');

      expect(second, isNull); // the second tap did nothing
      api.completer.complete(const DecisionOk({}));
      await first;
      expect(api.calls, 1);
    },
  );

  test('approving with a ref the queue is not sitting on errors instead of '
      'approving whatever the cursor points at', () async {
    final api = FakeDecisionApi();
    final h = harness(api: api);
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

    final dest = await queue.approveCurrent(
      cardRef: 'RLY-B', // the queue is sitting on RLY-A
      boardSlug: 'relay',
    );

    expect(dest, isNull);
    expect(
      api.approved,
      isEmpty,
      reason: 'approve is irreversible — never fire it at the wrong card',
    );
    expect(h.container.read(reviewQueueProvider).error, isNotNull);
    expect(h.container.read(reviewQueueProvider).index, 0);
  });

  test('approving a board slug the queue disagrees with errors the same way '
      '(refs are only unique within a board)', () async {
    final api = FakeDecisionApi();
    final h = harness(api: api);
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(
      rows: [row('RLY-A', slug: 'relay')],
      atRef: 'RLY-A',
    );

    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'other-board',
    );

    expect(dest, isNull);
    expect(api.approved, isEmpty);
    expect(h.container.read(reviewQueueProvider).error, isNotNull);
  });

  test('approving against an empty queue errors instead of returning null '
      'with no signal', () async {
    final h = harness(api: FakeDecisionApi());
    final queue = h.container.read(reviewQueueProvider.notifier);
    // No enter() — a genuine cold deep link before anything seeded.

    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

    expect(dest, isNull);
    expect(h.container.read(reviewQueueProvider).error, isNotNull);
  });

  test('enterSingle seeds a one-item snapshot whose decision walks into the '
      'live feed', () async {
    final feed = FakeFeedRepository([
      page([row('RLY-D')]),
    ]);
    final h = harness(api: FakeDecisionApi(), feed: feed);
    final queue = h.container.read(reviewQueueProvider.notifier);

    queue.enterSingle(QueueItem.fromRow(row('RLY-X')));
    final dest = await queue.approveCurrent(
      cardRef: 'RLY-X',
      boardSlug: 'relay',
    );

    expect(dest, '/cards/RLY-D?board=relay&kind=in_review');
    expect(
      feed.calls,
      1,
      reason: 'end of the one-item snapshot refetches once',
    );
    expect(h.container.read(reviewQueueProvider).banner, 'Approved · RLY-X');
  });

  test('enterSingle clears a lingering banner and error', () async {
    final h = harness(api: FakeDecisionApi(), feed: FakeFeedRepository());
    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A')], atRef: 'RLY-A');
    await queue.approveCurrent(cardRef: 'RLY-A', boardSlug: 'relay');
    expect(h.container.read(reviewQueueProvider).banner, isNotNull);

    queue.enterSingle(QueueItem.fromRow(row('RLY-X')));

    final state = h.container.read(reviewQueueProvider);
    expect(state.banner, isNull);
    expect(state.error, isNull);
    expect(state.items.map((i) => i.ref), ['RLY-X']);
  });

  test('a mid-queue approve drops the row from the live inbox immediately and '
      'fires one background reconcile (RLY-128 D2)', () async {
    final feed = StagedFeedRepository(page([row('RLY-A'), row('RLY-B')]));
    final h = harness(api: FakeDecisionApi(), feed: feed);
    await h.container.read(feedControllerProvider.future);
    expect(feed.calls, 1);

    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

    expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
    // Optimistic: gone even though the reconcile hasn't answered yet.
    final inbox = h.container.read(feedControllerProvider).value!;
    expect(inbox.rows.map((r) => r.ref), ['RLY-B']);
    expect(inbox.count, 1);
    expect(feed.calls, 2, reason: 'the background reconcile fired');

    // The reconcile lands and is authoritative.
    feed.pending.complete(page([row('RLY-B')]));
    await pumpEventQueue();
    expect(
      h.container.read(feedControllerProvider).value!.rows.map((r) => r.ref),
      ['RLY-B'],
    );
  });

  test('a background reconcile that fails leaves the optimistic removal intact '
      'instead of flipping the inbox to the error screen', () async {
    final feed = StagedFeedRepository(page([row('RLY-A'), row('RLY-B')]));
    final h = harness(api: FakeDecisionApi(), feed: feed);
    await h.container.read(feedControllerProvider.future);

    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );
    expect(dest, '/cards/RLY-B?board=relay&kind=in_review');

    // The background reconcile fails (a transient blip) — mid-queue, so a
    // real screen (the next card) is already showing, not the inbox.
    feed.pending.completeError(const ApiException('down'));
    await pumpEventQueue();

    final inbox = h.container.read(feedControllerProvider);
    expect(
      inbox.hasError,
      isFalse,
      reason:
          'a flaky automatic reconcile must not undo the optimistic '
          'removeRow and replace it with the full-screen error state',
    );
    expect(inbox.value!.rows.map((r) => r.ref), ['RLY-B']);
  });

  test('an already-handled 422 also drops the row — either way it no longer '
      'needs you', () async {
    final feed = StagedFeedRepository(page([row('RLY-A'), row('RLY-B')]));
    final h = harness(
      api: FakeDecisionApi(
        const DecisionFailed(
          'not_in_review',
          'This card is not in a review stage',
        ),
      ),
      feed: feed,
    );
    await h.container.read(feedControllerProvider.future);

    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

    expect(dest, '/cards/RLY-B?board=relay&kind=in_review');
    expect(
      h.container.read(feedControllerProvider).value!.rows.map((r) => r.ref),
      ['RLY-B'],
    );
    expect(feed.calls, 2);
  });

  test(
    'an answered needs_input row leaves the live inbox the same way',
    () async {
      final feed = StagedFeedRepository(
        page([
          row('RLY-A', kind: 'needs_input'),
          row('RLY-B', kind: 'needs_input'),
        ]),
      );
      final h = harness(api: FakeDecisionApi(), feed: feed);
      await h.container.read(feedControllerProvider.future);

      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(
        rows: [
          row('RLY-A', kind: 'needs_input'),
          row('RLY-B', kind: 'needs_input'),
        ],
        atRef: 'RLY-A',
      );
      await queue.answerCurrent(text: 'eu, please');

      expect(
        h.container.read(feedControllerProvider).value!.rows.map((r) => r.ref),
        ['RLY-B'],
      );
      expect(feed.calls, 2);
    },
  );

  test('a real failure touches neither the inbox nor the network', () async {
    final feed = StagedFeedRepository(page([row('RLY-A'), row('RLY-B')]));
    final h = harness(
      api: FakeDecisionApi(
        const DecisionFailed(
          'network',
          'Network error — could not reach Relay.',
        ),
      ),
      feed: feed,
    );
    await h.container.read(feedControllerProvider.future);

    final queue = h.container.read(reviewQueueProvider.notifier);
    queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
    final dest = await queue.approveCurrent(
      cardRef: 'RLY-A',
      boardSlug: 'relay',
    );

    expect(dest, isNull);
    expect(
      h.container.read(feedControllerProvider).value!.rows.map((r) => r.ref),
      ['RLY-A', 'RLY-B'],
    );
    expect(
      feed.calls,
      1,
      reason: 'no reconcile for a decision that did not settle',
    );
  });

  test(
    'a cold container pays nothing — no live inbox means no reconcile fetch',
    () async {
      final feed = FakeFeedRepository();
      final h = harness(api: FakeDecisionApi(), feed: feed);
      // No feedControllerProvider read anywhere — the inbox was never built.

      final queue = h.container.read(reviewQueueProvider.notifier);
      queue.enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
      await queue.approveCurrent(cardRef: 'RLY-A', boardSlug: 'relay');

      expect(feed.calls, 0);
    },
  );
}
