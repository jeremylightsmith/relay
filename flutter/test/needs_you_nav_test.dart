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
    'tapping a NEEDS INPUT row lands on the same card host a REVIEW row does (RLY-156)',
    (tester) async {
      final repo = FakeFeedRepository(
        page: FeedPage(
          rows: [makeRow(ref: 'RLY-2', kind: 'needs_input')],
          meta: const FeedMeta(count: 1),
        ),
      );
      await pumpShell(tester, repo);

      await tester.tap(find.byKey(const Key('inbox_row_RLY-2')));
      await tester.pumpAndSettle();

      final screen = tester.widget<CardScreen>(find.byType(CardScreen));
      expect(screen.cardRef, 'RLY-2');
      expect(screen.boardSlug, 'rly');
      expect(screen.kind, 'needs_input');

      // The host renders no native action bar for a needs_input card — answering
      // happens in the web stepper inside the webview body.
      expect(find.byKey(const Key('card_approve')), findsNothing);
      expect(find.byKey(const Key('card_reject')), findsNothing);
    },
  );

  testWidgets(
    'returning from a card inside the 15s guard does not refetch — the focus '
    'listener is throttled (RLY-128 D1)',
    (tester) async {
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

      expect(repo.calls, 1, reason: 'fetched moments ago — the guard skips');
    },
  );
}
