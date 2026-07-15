import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/card/card_placeholder_screen.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;

Future<void> pumpShell(
  WidgetTester tester,
  FakeFeedRepository repo, {
  List<RouteBase> extraRoutes = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feedRepositoryProvider.overrideWithValue(repo),
        authTokenProvider.overrideWithValue('relayu_test'),
      ],
      child: MaterialApp.router(
        theme: RelayTheme.light,
        routerConfig: buildRouter(extraRoutes: extraRoutes),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'tapping a REVIEW row routes to /card/:ref carrying ref and kind',
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

      final screen = tester.widget<CardPlaceholderScreen>(
        find.byType(CardPlaceholderScreen),
      );
      expect(screen.cardRef, 'RLY-1');
      expect(screen.kind, 'in_review');
    },
  );

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

  testWidgets('the placeholder reads as a stub and shows what it received', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [makeRow(ref: 'RLY-1')],
        meta: const FeedMeta(count: 1),
      ),
    );
    await pumpShell(tester, repo);

    await tester.tap(find.byKey(const Key('inbox_row_RLY-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('card_placeholder')), findsOneWidget);
    expect(find.textContaining('RLY-1'), findsWidgets);
    expect(find.textContaining('in_review'), findsWidgets);
    // Plainly provisional: no card content, no action bar.
    expect(find.text('Approve'), findsNothing);
    expect(find.text('Reject'), findsNothing);
  });

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

    // Pop back to the inbox via the placeholder's AppBar back button.
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(repo.calls, 2);
  });
}
