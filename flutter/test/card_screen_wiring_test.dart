import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/api/plan_paused.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/card/card_nav_context.dart';
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
        backLabel: s.uri.queryParameters['back'],
        navContext: s.extra as CardNavContext?,
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
  ThemeData? theme,
  String at = '/cards/RLY-A?board=relay&kind=in_review',
}) async {
  final container = ProviderContainer(
    overrides: [
      decisionApiProvider.overrideWithValue(api),
      boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs()),
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
      child: MaterialApp.router(
        theme: theme ?? RelayTheme.light,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  router.push(at);
  await tester.pumpAndSettle();
  return (container: container, router: router);
}

void main() {
  group('RE405: CardScreen owns the top safe-area inset', () {
    const body = ValueKey('card_body_RLY-A');

    Scaffold cardScaffold(WidgetTester tester) => tester.widget<Scaffold>(
      find
          .ancestor(of: find.byKey(body), matching: find.byType(Scaffold))
          .first,
    );

    testWidgets('the card body starts below the status bar', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 47);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);

      await pumpCardHost(tester, api: FakeDecisionApi());

      expect(tester.getTopLeft(find.byKey(body)).dy, 47.0);
    });

    testWidgets('the body SafeArea applies the top inset', (tester) async {
      await pumpCardHost(tester, api: FakeDecisionApi());

      final safeArea = tester.widget<SafeArea>(
        find
            .ancestor(of: find.byKey(body), matching: find.byType(SafeArea))
            .first,
      );
      expect(safeArea.top, isTrue);
    });

    testWidgets('the status-bar strip is the light theme surface', (
      tester,
    ) async {
      await pumpCardHost(tester, api: FakeDecisionApi());

      expect(
        cardScaffold(tester).backgroundColor,
        RelayTheme.light.colorScheme.surface,
      );
    });

    testWidgets('the status-bar strip is the dark theme surface', (
      tester,
    ) async {
      await pumpCardHost(
        tester,
        api: FakeDecisionApi(),
        theme: RelayTheme.dark,
      );

      expect(
        cardScaffold(tester).backgroundColor,
        RelayTheme.dark.colorScheme.surface,
      );
    });
  });

  testWidgets(
    'Approve posts the decision and lands on the next card with the banner',
    (tester) async {
      final api = FakeDecisionApi();
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(api.approved, ['RLY-A']);
      expect(find.byKey(const ValueKey('card_body_RLY-B')), findsOneWidget);
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
      expect(find.byKey(const ValueKey('card_body_RLY-B')), findsOneWidget);
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

      expect(find.byKey(const ValueKey('card_body_RLY-B')), findsOneWidget);
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
          'Network error — could not reach Hamaca.',
        ),
      );
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('card_body_RLY-A')),
        findsOneWidget,
        reason: 'a failed decision must never advance',
      );
      expect(
        find.text('Network error — could not reach Hamaca.'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'RE466: a plan_paused refusal explains itself inline — no snackbar, no Retry',
    (tester) async {
      final api = FakeDecisionApi(
        const DecisionFailed('plan_paused', "This board's plan is paused."),
      );
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('card_plan_paused')),
          matching: find.text(planPausedMessage),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(
        find.byKey(const ValueKey('card_body_RLY-A')),
        findsOneWidget,
        reason: 'the card did not move',
      );
      expect(api.approved, ['RLY-A'], reason: 'no retry loop');
    },
  );

  testWidgets(
    'RE466: a network failure still gets the snackbar + Retry, not the paused notice',
    (tester) async {
      final api = FakeDecisionApi(
        const DecisionFailed(
          'network',
          'Network error — could not reach Hamaca.',
        ),
      );
      await pumpCardHost(tester, api: api);

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byKey(const Key('card_plan_paused')), findsNothing);
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

      expect(find.byKey(const ValueKey('card_body_RLY-B')), findsOneWidget);
      expect(
        mounts,
        hasLength(2),
        reason:
            'the same /cards/:ref page key reuses the State — the keyed '
            'body must still remount per card',
      );
    },
  );

  group('RE474: a dependency tap on a card pushes that card natively', () {
    const tap = {
      'ref': 'RE2',
      'board': 'demo',
      'kind': null,
      'cards': [
        {'ref': 'RE2', 'kind': null},
        {'ref': 'RE5', 'kind': null},
      ],
    };

    /// A stand-in for the webview: each button fires the exact call the
    /// `relayCardTap` JS callback makes, with the given args.
    Widget tapBody(BuildContext ctx) => Column(
      children: [
        TextButton(
          key: const Key('dep_tap'),
          onPressed: () => CardScreen.onCardTap(ctx, [tap]),
          child: const Text('RE2'),
        ),
        TextButton(
          key: const Key('dep_tap_no_args'),
          onPressed: () => CardScreen.onCardTap(ctx, []),
          child: const Text('none'),
        ),
        TextButton(
          key: const Key('dep_tap_no_ref'),
          onPressed: () => CardScreen.onCardTap(ctx, [
            {'board': 'demo'},
          ]),
          child: const Text('no ref'),
        ),
      ],
    );

    Future<GoRouter> pumpRe1(WidgetTester tester) async {
      final h = await pumpCardHost(
        tester,
        api: FakeDecisionApi(),
        seedQueue: false,
        bodyBuilder: tapBody,
        at: '/cards/RE1?board=demo&back=Board',
      );
      return h.router;
    }

    CardScreen topCard(WidgetTester tester) =>
        tester.widget<CardScreen>(find.byType(CardScreen));

    testWidgets('the tapped card is pushed with the originating card as its '
        'back label and the tapped column as its ‹ › context', (tester) async {
      await pumpRe1(tester);

      await tester.tap(find.byKey(const Key('dep_tap')));
      await tester.pumpAndSettle();

      final card = topCard(tester);
      expect(card.cardRef, 'RE2');
      expect(card.boardSlug, 'demo');
      expect(card.backLabel, 'RE1');
      expect(card.navContext?.next?.ref, 'RE5');
    });

    testWidgets('Back returns to the card the tap came from', (tester) async {
      final router = await pumpRe1(tester);
      await tester.tap(find.byKey(const Key('dep_tap')));
      await tester.pumpAndSettle();
      expect(topCard(tester).cardRef, 'RE2');

      router.pop();
      await tester.pumpAndSettle();

      final card = topCard(tester);
      expect(card.cardRef, 'RE1');
      expect(card.backLabel, 'Board');
    });

    testWidgets('a tap with no ref pushes nothing', (tester) async {
      final router = await pumpRe1(tester);

      await tester.tap(find.byKey(const Key('dep_tap_no_args')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dep_tap_no_ref')));
      await tester.pumpAndSettle();

      expect(router.state.uri.toString(), startsWith('/cards/RE1'));
      expect(router.canPop(), isTrue, reason: 'RE1 still sits on the inbox');
      expect(find.byType(CardScreen, skipOffstage: false), findsOneWidget);
      expect(topCard(tester).cardRef, 'RE1');
    });
  });
}
