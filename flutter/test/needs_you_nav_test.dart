import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';
import 'package:relay_mobile/features/needs_you/widgets/caught_up.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;
import 'review_queue_test.dart' show FakeDecisionApi;

Future<void> pumpShell(
  WidgetTester tester,
  FakeFeedRepository repo, {
  List<RouteBase> extraRoutes = const [],
  DecisionApi? decisionApi,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feedRepositoryProvider.overrideWithValue(repo),
        authTokenProvider.overrideWithValue('relayu_test'),
        decisionApiProvider.overrideWithValue(decisionApi ?? FakeDecisionApi()),
      ],
      child: MaterialApp.router(
        theme: RelayTheme.light,
        routerConfig: buildRouter(
          extraRoutes: extraRoutes,
          // The tap now lands on the real card host, whose webview has no host-platform
          // implementation under `flutter test` (RLY-81).
          cardBodyBuilder: (_) =>
              const SizedBox.shrink(key: Key('stub_card_body')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'tapping a REVIEW row routes to /cards/:ref carrying ref, board and kind',
    (tester) async {
      final repo = FakeFeedRepository(
        page: FeedPage(
          rows: [makeRow(ref: 'RLY-1', kind: 'in_review')],
          meta: const FeedMeta(count: 1),
        ),
      );
      await pumpShell(tester, repo);

      await tester.tap(find.byKey(const Key('inbox_row_RLY-1')));
      await tester.pumpAndSettle();

      final screen = tester.widget<CardScreen>(find.byType(CardScreen));
      expect(screen.cardRef, 'RLY-1');
      expect(screen.boardSlug, 'rly');
      expect(screen.kind, 'in_review');
    },
  );

  testWidgets('a REVIEW row lands on the persistent approve/reject bar', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [makeRow(ref: 'RLY-1', kind: 'in_review')],
        meta: const FeedMeta(count: 1),
      ),
    );
    await pumpShell(tester, repo);

    await tester.tap(find.byKey(const Key('inbox_row_RLY-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('card_approve')), findsOneWidget);
    expect(find.byKey(const Key('card_reject')), findsOneWidget);
  });

  testWidgets(
    'tapping a NEEDS INPUT row routes to the answer screen (RLY-89)',
    (tester) async {
      // Task 3 registers the real `/card/:ref/answer` screen; here only the
      // destination matters, so a stub stands in for it (same technique
      // card_deep_link_test.dart uses for the not-yet-buildable webview body).
      final repo = FakeFeedRepository(
        page: FeedPage(
          rows: [makeRow(ref: 'RLY-2', kind: 'needs_input')],
          meta: const FeedMeta(count: 1),
        ),
      );
      await pumpShell(
        tester,
        repo,
        extraRoutes: [
          GoRoute(
            path: '/card/:ref/answer',
            builder: (context, state) => SizedBox(
              key: Key('answer_stub_${state.pathParameters['ref']}'),
            ),
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('inbox_row_RLY-2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('answer_stub_RLY-2')), findsOneWidget);
    },
  );

  testWidgets('returning from a card refetches the feed', (tester) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [makeRow(ref: 'RLY-1')],
        meta: const FeedMeta(count: 1),
      ),
    );
    await pumpShell(tester, repo);
    expect(repo.calls, 1);

    await tester.tap(find.byKey(const Key('inbox_row_RLY-1')));
    await tester.pumpAndSettle();

    // Pop back to the inbox via the card host's AppBar back button.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(repo.calls, 2);
  });

  testWidgets(
    'clearing the queue (a legacy row, then a structured one) auto-advances '
    'and lands on a genuinely caught-up EMPTY-01, not a stale inbox (RLY-89 '
    'acceptance smoke)',
    (tester) async {
      final legacy = FeedRow(
        ref: 'RLY-1',
        title: 'Legacy question card',
        board: const FeedBoard(name: 'Relay', key: 'RLY', slug: 'relay'),
        status: 'needs_input',
        kind: 'needs_input',
        stage: 'Prep',
        reason: 'Which region?',
        blockedAt: DateTime.utc(2026, 7, 15, 11),
      );
      final structured = FeedRow(
        ref: 'RLY-2',
        title: 'Structured question card',
        board: const FeedBoard(name: 'Relay', key: 'RLY', slug: 'relay'),
        status: 'needs_input',
        kind: 'needs_input',
        stage: 'Prep',
        blockedAt: DateTime.utc(2026, 7, 15, 10),
        questions: const [
          FeedQuestion(
            prompt: 'Which region?',
            options: ['us', 'eu'],
            allowText: true,
          ),
          FeedQuestion(
            prompt: 'Ship it?',
            options: ['yes', 'no'],
            allowText: true,
          ),
        ],
      );

      final repo = FakeFeedRepository(
        page: FeedPage(
          rows: [legacy, structured],
          meta: const FeedMeta(count: 2),
        ),
      );
      await pumpShell(tester, repo);
      expect(find.text('2 decisions waiting'), findsOneWidget);

      // The legacy row: free text, then Send.
      await tester.tap(find.byKey(const Key('inbox_row_RLY-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('answer_text')),
        'eu, please',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('answer_submit')));
      await tester.pumpAndSettle();

      // Auto-advanced into the structured card's first step — mid-snapshot, so
      // no walk refetch; the answered card's D2 background reconcile (RLY-128)
      // is the one extra request.
      expect(find.text('Which region?'), findsOneWidget);
      expect(repo.calls, 2);
      await tester.tap(find.byKey(const Key('answer_option_1'))); // eu
      await tester.pump();
      await tester.tap(find.byKey(const Key('answer_submit')));
      await tester.pumpAndSettle();

      expect(find.text('Ship it?'), findsOneWidget);
      // By the time the last item lands, the server has nothing fresh left.
      repo.page = const FeedPage(rows: [], meta: FeedMeta(count: 0));
      await tester.tap(find.byKey(const Key('answer_option_0'))); // yes
      await tester.pump();
      await tester.tap(find.byKey(const Key('answer_submit')));
      await tester.pumpAndSettle();

      // Lands on EMPTY-01, genuinely caught up — not the stale "2 decisions
      // waiting" inbox this regressed to.
      expect(find.byType(CaughtUp), findsOneWidget);
      expect(find.text('nothing waiting'), findsOneWidget);
      expect(find.text('2 decisions waiting'), findsNothing);
      expect(find.byKey(const Key('inbox_row_RLY-1')), findsNothing);
      expect(find.byKey(const Key('inbox_row_RLY-2')), findsNothing);
      // One D2 reconcile per answered card (RLY-128) plus the end-of-snapshot
      // refetch — landing on the inbox costs nothing further.
      expect(repo.calls, 4);
    },
  );
}
