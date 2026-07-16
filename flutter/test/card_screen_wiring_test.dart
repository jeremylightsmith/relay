import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/decisions/review_queue.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'review_queue_test.dart'
    show BlockedDecisionApi, FakeDecisionApi, FakeFeedRepository, row;
import 'support/fake_auth.dart';

/// Counts (re)mounts of the body slot — the webview stand-in. Advancing
/// RLY-A → RLY-B reuses the route State (same `/cards/:ref` page key, see
/// AnswerScreen's didUpdateWidget note), so without a per-card key the real
/// InAppWebView would keep showing the *old* card's page.
class MountCounter extends StatefulWidget {
  const MountCounter(this.log, {super.key});
  final List<int> log;
  @override
  State<MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.log.add(1);
  }

  @override
  Widget build(BuildContext context) =>
      const Text('card body', key: Key('stub_card_body'));
}

GoRouter _router({WidgetBuilder? bodyBuilder}) => GoRouter(
  initialLocation: '/needs-you',
  routes: [
    GoRoute(
      path: '/needs-you',
      builder: (c, s) =>
          const Scaffold(body: Text('inbox', key: Key('inbox_stub'))),
    ),
    GoRoute(
      path: '/cards/:ref',
      builder: (c, s) => CardScreen(
        cardRef: s.pathParameters['ref']!,
        boardSlug: s.uri.queryParameters['board'] ?? '',
        kind: s.uri.queryParameters['kind'],
        bodyBuilder: bodyBuilder ?? (_) => const Text('card body'),
      ),
    ),
    GoRoute(
      path: '/card/:ref/reject',
      builder: (c, s) => Scaffold(
        body: Text(
          'reject ${s.pathParameters['ref']}',
          key: const Key('reject_stub'),
        ),
      ),
    ),
  ],
);

Future<({ProviderContainer container, GoRouter router})> pumpCardHost(
  WidgetTester tester, {
  required DecisionApi api,
  FeedRepository? feed,
  bool seedQueue = true,
  WidgetBuilder? bodyBuilder,
}) async {
  final container = ProviderContainer(
    overrides: [
      decisionApiProvider.overrideWithValue(api),
      feedRepositoryProvider.overrideWithValue(feed ?? FakeFeedRepository()),
      authProvider.overrideWith(
        () => FakeAuthController(
          const AuthState(status: AuthStatus.signedIn, token: 'relayu_t'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  if (seedQueue) {
    // The inbox tap's snapshot: RLY-A first, RLY-B next.
    container
        .read(reviewQueueProvider.notifier)
        .enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');
  }
  final router = _router(bodyBuilder: bodyBuilder);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: RelayTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  router.push('/cards/RLY-A?board=relay&kind=in_review');
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

void main() {
  testWidgets(
    'Approve posts the decision and lands on the next card with the banner',
    (tester) async {
      final api = FakeDecisionApi();
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(api.approved, ['RLY-A']);
      expect(find.widgetWithText(AppBar, 'RLY-B'), findsOneWidget);
      // D1: no CORE-06 confirmation screen — the signal is this snackbar.
      expect(find.text('Approved · RLY-A'), findsOneWidget);
    },
  );

  testWidgets(
    'a double-tap issues one POST — the bar disables while in flight',
    (tester) async {
      final api = BlockedDecisionApi();
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pump();

      final approve = tester.widget<FilledButton>(
        find.byKey(const Key('card_approve')),
      );
      final reject = tester.widget<OutlinedButton>(
        find.byKey(const Key('card_reject')),
      );
      expect(approve.onPressed, isNull, reason: 'disabled while in flight');
      expect(reject.onPressed, isNull, reason: 'disabled while in flight');

      await tester.tap(
        find.byKey(const Key('card_approve')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(api.calls, 1);

      api.completer.complete(const DecisionOk({}));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'RLY-B'), findsOneWidget);
    },
  );

  testWidgets('Reject opens the CORE-07 note screen without posting anything', (
    tester,
  ) async {
    final api = FakeDecisionApi();
    await pumpCardHost(tester, api: api);

    await tester.tap(find.byKey(const Key('card_reject')));
    await tester.pumpAndSettle();

    expect(find.text('reject RLY-A'), findsOneWidget);
    expect(api.approved, isEmpty);
    expect(api.rejected, isEmpty);
  });

  testWidgets(
    'an already-handled card is skipped with the banner, not errored',
    (tester) async {
      final api = FakeDecisionApi(
        const DecisionFailed(
          'not_in_review',
          'This card is not in a review stage',
        ),
      );
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'RLY-B'), findsOneWidget);
      expect(find.text('Already handled · RLY-A'), findsOneWidget);
      expect(
        find.text('This card is not in a review stage'),
        findsNothing,
        reason: 'a skip is not an error',
      );
    },
  );

  testWidgets(
    'a network failure stays on the card and shows the message with Retry',
    (tester) async {
      final api = FakeDecisionApi(
        const DecisionFailed(
          'network',
          'Network error — could not reach Relay.',
        ),
      );
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(AppBar, 'RLY-A'),
        findsOneWidget,
        reason: 'a failed decision must never advance',
      );
      expect(
        find.text('Network error — could not reach Relay.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets('clearing the last item lands on the inbox', (tester) async {
    final api = FakeDecisionApi();
    await pumpCardHost(tester, api: api);

    await tester.tap(find.byKey(const Key('card_approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('card_approve')));
    await tester.pumpAndSettle();

    expect(api.approved, ['RLY-A', 'RLY-B']);
    // The refetch found nothing fresh → the inbox, which renders EMPTY-01
    // (RLY-85's) — never a CORE-08 confirmation screen (D1).
    expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
  });

  testWidgets(
    'a deep-link arrival with no snapshot seeds this card and the bar works',
    (tester) async {
      final api = FakeDecisionApi();
      final feed = FakeFeedRepository();
      await pumpCardHost(tester, api: api, feed: feed, seedQueue: false);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(api.approved, ['RLY-A']);
      expect(
        feed.calls,
        1,
        reason: 'end of the one-item snapshot picks up the live feed',
      );
      expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
    },
  );

  testWidgets(
    'landing on a card the queue is not sitting on reseeds, so approve '
    'fires at the on-screen card — never the stale cursor',
    (tester) async {
      final api = FakeDecisionApi();
      final h = await pumpCardHost(tester, api: api); // cursor on RLY-A
      h.router.push('/cards/RLY-X?board=relay&kind=in_review'); // push tap
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(api.approved, ['RLY-X']);
    },
  );

  testWidgets(
    'advancing to the next card remounts the body so the webview loads '
    'the new card',
    (tester) async {
      final mounts = <int>[];
      await pumpCardHost(
        tester,
        api: FakeDecisionApi(),
        bodyBuilder: (_) => MountCounter(mounts),
      );
      expect(mounts, hasLength(1));

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'RLY-B'), findsOneWidget);
      expect(
        mounts,
        hasLength(2),
        reason:
            'the same /cards/:ref page key reuses the State — the keyed '
            'body must still remount per card',
      );
    },
  );
}
