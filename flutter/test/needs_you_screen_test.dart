import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';
import 'package:relay_mobile/features/needs_you/needs_you_screen.dart';
import 'package:relay_mobile/features/needs_you/widgets/caught_up.dart';
import 'package:relay_mobile/features/needs_you/widgets/working_strip.dart';

/// A repository that answers from memory and counts calls — no network, no Dio.
class FakeFeedRepository implements FeedRepository {
  FakeFeedRepository({this.page, this.error});

  FeedPage? page;
  Object? error;
  int calls = 0;

  @override
  Future<FeedPage> fetchFeed() async {
    calls++;
    if (error != null) throw error!;
    return page ?? const FeedPage(rows: [], meta: FeedMeta(count: 0));
  }
}

FeedRow makeRow({
  String ref = 'RLY-1',
  String title = 'Rewrite the onboarding tooltips',
  String kind = 'in_review',
  String boardKey = 'RLY',
  DateTime? blockedAt,
  FeedStageGroup? stageGroup,
}) => FeedRow(
  ref: ref,
  title: title,
  board: FeedBoard(name: 'Relay', key: boardKey, slug: boardKey.toLowerCase()),
  status: kind,
  kind: kind,
  reason: 'Review',
  blockedAt: blockedAt ?? DateTime.utc(2026, 7, 15, 11, 56),
  stageGroup: stageGroup,
);

Future<void> pumpInbox(
  WidgetTester tester, {
  required FakeFeedRepository repo,
  String? token = 'relayu_test',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        feedRepositoryProvider.overrideWithValue(repo),
        authTokenProvider.overrideWithValue(token),
      ],
      child: MaterialApp(
        theme: RelayTheme.light,
        home: const Scaffold(body: NeedsYouScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a populated feed renders one row per decision, newest first', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [
          makeRow(ref: 'RLY-1', blockedAt: DateTime.utc(2026, 7, 15, 11, 56)),
          makeRow(
            ref: 'RLY-2',
            title: 'CSV export — column order',
            kind: 'needs_input',
            blockedAt: DateTime.utc(2026, 7, 15, 11),
          ),
        ],
        meta: const FeedMeta(count: 2),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byKey(const Key('inbox_row_RLY-1')), findsOneWidget);
    expect(find.byKey(const Key('inbox_row_RLY-2')), findsOneWidget);
    expect(find.text('REVIEW'), findsOneWidget);
    expect(find.text('NEEDS INPUT'), findsOneWidget);
    expect(find.text('Rewrite the onboarding tooltips'), findsOneWidget);
    expect(find.byType(CaughtUp), findsNothing);

    // HOME-01's live subtitle.
    expect(find.text('2 decisions waiting'), findsOneWidget);
  });

  testWidgets('the subtitle is singular for a single decision', (tester) async {
    final repo = FakeFeedRepository(
      page: FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1)),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.text('1 decision waiting'), findsOneWidget);
  });

  testWidgets('an empty feed renders EMPTY-01 and no rows', (tester) async {
    await pumpInbox(tester, repo: FakeFeedRepository());

    expect(find.byType(CaughtUp), findsOneWidget);
    expect(find.text("You're all caught up"), findsOneWidget);
    expect(
      find.text(
        "Relay AI is working. We'll ping you the moment it needs a decision.",
      ),
      findsOneWidget,
    );
    expect(find.text('nothing waiting'), findsOneWidget);
    expect(find.byKey(const Key('inbox_row_RLY-1')), findsNothing);
  });

  testWidgets('the board chip is absent when the feed spans one board', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [
          makeRow(ref: 'RLY-1'),
          makeRow(ref: 'RLY-2'),
        ],
        meta: const FeedMeta(count: 2),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byKey(const Key('board_chip_RLY-1')), findsNothing);
    expect(find.byKey(const Key('board_chip_RLY-2')), findsNothing);
  });

  testWidgets('the board chip shows the key when the feed spans two boards', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [
          makeRow(ref: 'RLY-1', boardKey: 'RLY'),
          makeRow(ref: 'MKT-1', boardKey: 'MKT'),
        ],
        meta: const FeedMeta(count: 2),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byKey(const Key('board_chip_RLY-1')), findsOneWidget);
    expect(find.byKey(const Key('board_chip_MKT-1')), findsOneWidget);
    expect(find.text('MKT'), findsOneWidget);
  });

  testWidgets(
    'the working strip is hidden when working_count is absent (F4 as merged)',
    (tester) async {
      final repo = FakeFeedRepository(
        page: FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1)),
      );
      await pumpInbox(tester, repo: repo);

      expect(find.byType(WorkingStrip), findsNothing);
    },
  );

  testWidgets('the working strip is hidden when working_count is 0', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [makeRow()],
        meta: const FeedMeta(count: 1, workingCount: 0),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byType(WorkingStrip), findsNothing);
  });

  testWidgets(
    'the working strip shows the count when > 0, with no progress %',
    (tester) async {
      final repo = FakeFeedRepository(
        page: FeedPage(
          rows: [makeRow()],
          meta: const FeedMeta(count: 1, workingCount: 3),
        ),
      );
      await pumpInbox(tester, repo: repo);

      expect(find.byType(WorkingStrip), findsOneWidget);
      expect(find.text('working · 3 cards'), findsOneWidget);
      expect(find.text('Relay AI is on it'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
    },
  );

  testWidgets('the working strip also shows on the caught-up screen', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: const FeedPage(rows: [], meta: FeedMeta(count: 0, workingCount: 3)),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byType(CaughtUp), findsOneWidget);
    expect(find.byType(WorkingStrip), findsOneWidget);
  });

  testWidgets('a failure renders an error + Retry, never the caught-up state', (
    tester,
  ) async {
    final repo = FakeFeedRepository(error: const ApiException('Network error'));
    await pumpInbox(tester, repo: repo);

    expect(find.byKey(const Key('feed_error')), findsOneWidget);
    expect(find.byKey(const Key('feed_retry')), findsOneWidget);
    expect(find.text('Network error'), findsOneWidget);
    expect(find.byType(CaughtUp), findsNothing);
  });

  testWidgets(
    'a non-ApiException failure renders the generic message, never the raw exception text',
    (tester) async {
      final repo = FakeFeedRepository(
        error: const FormatException('Invalid date format (at character 5)'),
      );
      await pumpInbox(tester, repo: repo);

      expect(find.byKey(const Key('feed_error')), findsOneWidget);
      expect(find.text('Something went wrong.'), findsOneWidget);
      expect(find.textContaining('FormatException'), findsNothing);
      expect(find.textContaining('Invalid date format'), findsNothing);
    },
  );

  testWidgets('Retry re-calls the repository and recovers', (tester) async {
    final repo = FakeFeedRepository(error: const ApiException('Network error'));
    await pumpInbox(tester, repo: repo);
    expect(repo.calls, 1);

    repo.error = null;
    repo.page = FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1));
    await tester.tap(find.byKey(const Key('feed_retry')));
    await tester.pumpAndSettle();

    expect(repo.calls, 2);
    expect(find.byKey(const Key('inbox_row_RLY-1')), findsOneWidget);
  });

  testWidgets(
    'a null token renders the error state, not caught-up, and never fetches',
    (tester) async {
      final repo = FakeFeedRepository();
      await pumpInbox(tester, repo: repo, token: null);

      expect(find.byKey(const Key('feed_error')), findsOneWidget);
      expect(find.byType(CaughtUp), findsNothing);
      expect(find.textContaining('token'), findsOneWidget);
      expect(repo.calls, 0);
    },
  );

  testWidgets('pull-to-refresh triggers exactly one refetch', (tester) async {
    final repo = FakeFeedRepository(
      page: FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1)),
    );
    await pumpInbox(tester, repo: repo);
    expect(repo.calls, 1);

    await tester.fling(
      find.byKey(const Key('inbox_list')),
      const Offset(0, 320),
      1000,
    );
    await tester.pumpAndSettle();

    expect(repo.calls, 2);
  });

  testWidgets('an app resume triggers exactly one refetch', (tester) async {
    final repo = FakeFeedRepository(
      page: FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1)),
    );
    await pumpInbox(tester, repo: repo);
    expect(repo.calls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(repo.calls, 2);
  });

  testWidgets('the age is derived from blocked_at', (tester) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [
          makeRow(
            blockedAt: DateTime.now().toUtc().subtract(
              const Duration(hours: 1),
            ),
          ),
        ],
        meta: const FeedMeta(count: 1),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.text('1h'), findsOneWidget);
  });

  testWidgets(
    'the row carries HOME-01\'s amber left accent and violet AI avatar',
    (tester) async {
      final repo = FakeFeedRepository(
        page: FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1)),
      );
      await pumpInbox(tester, repo: repo);

      // 5px amber left stripe — HOME-01's 3px accent × 1.585 (Relay Mobile.dc.html ~line 127).
      final accent = tester.widget<Container>(
        find.byKey(const Key('inbox_accent_RLY-1')),
      );
      expect(accent.color, RelayTheme.relayBlocked);
      expect(accent.constraints?.maxWidth, 5);

      // 32px violet circular avatar — HOME-01's 20px × 1.585.
      final avatar = tester.widget<Container>(
        find.byKey(const Key('inbox_avatar_RLY-1')),
      );
      expect((avatar.decoration as BoxDecoration).color, RelayTheme.relayAI);
      expect(avatar.constraints?.maxWidth, 32);
    },
  );

  testWidgets('the inbox files rows under their top-level stage bar', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [
          makeRow(
            ref: 'RLY-1',
            stageGroup: const FeedStageGroup(name: 'Spec', type: 'planning'),
          ),
          makeRow(
            ref: 'RLY-2',
            stageGroup: const FeedStageGroup(name: 'Code', type: 'work'),
          ),
          // A sub-lane card: the server already resolved it to its PARENT group.
          makeRow(
            ref: 'RLY-3',
            stageGroup: const FeedStageGroup(name: 'Code', type: 'work'),
          ),
        ],
        meta: const FeedMeta(count: 3),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byKey(const Key('stage_group_Spec')), findsOneWidget);
    expect(find.byKey(const Key('stage_group_Code')), findsOneWidget);
    // One CODE bar for both Code rows — no separate CODE · REVIEW group.
    expect(find.text('CODE'), findsOneWidget);

    // Groups follow first appearance, so Spec's bar sits above Code's.
    final spec = tester
        .getTopLeft(find.byKey(const Key('stage_group_Spec')))
        .dy;
    final code = tester
        .getTopLeft(find.byKey(const Key('stage_group_Code')))
        .dy;
    expect(spec, lessThan(code));
  });

  testWidgets('rows with no stage group still render, under one OTHER bar', (
    tester,
  ) async {
    final repo = FakeFeedRepository(
      page: FeedPage(
        rows: [
          makeRow(ref: 'RLY-1'),
          makeRow(ref: 'RLY-2'),
        ],
        meta: const FeedMeta(count: 2),
      ),
    );
    await pumpInbox(tester, repo: repo);

    expect(find.byKey(const Key('stage_group_other')), findsOneWidget);
    expect(find.byKey(const Key('inbox_row_RLY-1')), findsOneWidget);
    expect(find.byKey(const Key('inbox_row_RLY-2')), findsOneWidget);
  });
}
