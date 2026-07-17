import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/needs_you/feed_controller.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;
import 'review_queue_test.dart' show FakeDecisionApi;

/// Answers the first fetch; leaves every later one hanging, so a test can look
/// at the list *while* a focus refresh is in flight (D3: silent presentation).
class HangingSecondFetchRepository implements FeedRepository {
  HangingSecondFetchRepository(this.first);

  final FeedPage first;
  final pending = Completer<FeedPage>();
  int calls = 0;

  @override
  Future<FeedPage> fetchFeed() {
    calls++;
    return calls == 1 ? Future.value(first) : pending.future;
  }
}

FeedPage onePage() => FeedPage(
  rows: [makeRow(ref: 'RLY-1')],
  meta: const FeedMeta(count: 1),
);

Future<void> pumpFocusShell(
  WidgetTester tester, {
  required FeedRepository repo,
  required DateTime Function() clock,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feedRepositoryProvider.overrideWithValue(repo),
        authTokenProvider.overrideWithValue('relayu_test'),
        clockProvider.overrideWithValue(clock),
        decisionApiProvider.overrideWithValue(FakeDecisionApi()),
      ],
      child: MaterialApp.router(
        theme: RelayTheme.light,
        routerConfig: buildRouter(
          cardBodyBuilder: (_) =>
              const SizedBox.shrink(key: Key('stub_card_body')),
          boardBodyBuilder: (_) =>
              const SizedBox.shrink(key: Key('stub_board_body')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'switching Board → Needs You refetches once the feed is stale (D1)',
    (tester) async {
      var now = DateTime.utc(2026, 7, 16, 12);
      final repo = FakeFeedRepository(page: onePage());
      await pumpFocusShell(tester, repo: repo, clock: () => now);
      expect(repo.calls, 1);

      await tester.tap(find.byKey(const Key('nav_board')));
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 16));

      await tester.tap(find.byKey(const Key('nav_needs_you')));
      await tester.pumpAndSettle();

      expect(repo.calls, 2);
    },
  );

  testWidgets('switching back inside the 15s guard window does not refetch', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 7, 16, 12);
    final repo = FakeFeedRepository(page: onePage());
    await pumpFocusShell(tester, repo: repo, clock: () => now);

    await tester.tap(find.byKey(const Key('nav_board')));
    await tester.pumpAndSettle();
    now = now.add(const Duration(seconds: 5));

    await tester.tap(find.byKey(const Key('nav_needs_you')));
    await tester.pumpAndSettle();

    expect(repo.calls, 1, reason: 'fetched 5s ago — the guard skips');
  });

  testWidgets(
    'popping back from a pushed card refetches once the feed is stale',
    (tester) async {
      var now = DateTime.utc(2026, 7, 16, 12);
      final repo = FakeFeedRepository(page: onePage());
      await pumpFocusShell(tester, repo: repo, clock: () => now);
      expect(repo.calls, 1);

      await tester.tap(find.byKey(const Key('inbox_row_RLY-1')));
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 16));

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(repo.calls, 2);
    },
  );

  testWidgets(
    'a focus refresh is silent — the old list stays put, no spinner (D3)',
    (tester) async {
      var now = DateTime.utc(2026, 7, 16, 12);
      final repo = HangingSecondFetchRepository(onePage());
      await pumpFocusShell(tester, repo: repo, clock: () => now);

      await tester.tap(find.byKey(const Key('nav_board')));
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 16));
      await tester.tap(find.byKey(const Key('nav_needs_you')));
      await tester.pumpAndSettle();

      // The refresh is in flight, yet the old list is still on screen.
      expect(repo.calls, 2);
      expect(find.byKey(const Key('inbox_row_RLY-1')), findsOneWidget);
      expect(find.byKey(const Key('feed_loading')), findsNothing);

      // When it lands, the data swaps in place.
      repo.pending.complete(const FeedPage(rows: [], meta: FeedMeta(count: 0)));
      await tester.pumpAndSettle();
      expect(find.text('nothing waiting'), findsOneWidget);
      expect(find.byKey(const Key('inbox_row_RLY-1')), findsNothing);
    },
  );
}
