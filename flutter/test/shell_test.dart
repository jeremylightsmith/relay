import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/board/board_screen.dart';
import 'package:relay_mobile/features/boards/board_switcher.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;
import 'support/fake_boards.dart';

/// The tab shell in isolation (ungated). The auth gate is exercised separately in
/// auth_test.dart; here we assert the three-tab shell itself. The inbox's repository
/// is faked — the shell watches the feed count for its badge (D6), so pumping the
/// shell would otherwise fire a real request.
Future<void> pumpApp(
  WidgetTester tester, {
  FakeFeedRepository? repo,
  String? boardSlug,
  FakeBoardsRepository? boards,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardsRepositoryProvider.overrideWithValue(
          boards ?? FakeBoardsRepository(),
        ),
        boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs(boardSlug)),
        feedRepositoryProvider.overrideWithValue(repo ?? FakeFeedRepository()),
        authTokenProvider.overrideWithValue('relayu_test'),
      ],
      child: MaterialApp.router(
        theme: RelayTheme.light,
        routerConfig: buildRouter(
          boardBodyBuilder: (_) =>
              const Text('board body', key: Key('stub_board_body')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('boots to the Needs you inbox', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(const Key('needs_you_header')), findsOneWidget);
    expect(find.text('Needs you'), findsWidgets); // header + tab label
    expect(find.text('Arriving soon'), findsNothing);
  });

  testWidgets('the inbox header sits below the status bar / notch inset', (
    tester,
  ) async {
    // Simulate a device with a status bar / Dynamic Island: physical padding
    // at devicePixelRatio 1 so logical == physical for this assertion.
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 59);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await pumpApp(tester);

    final headerTop = tester
        .getTopLeft(find.byKey(const Key('needs_you_header')))
        .dy;
    expect(headerTop, greaterThanOrEqualTo(59));
  });

  testWidgets('shows exactly three destinations with stable keys, in order', (
    tester,
  ) async {
    await pumpApp(tester);
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations.length, 3);
    expect(find.byKey(const Key('nav_needs_you')), findsOneWidget);
    expect(find.byKey(const Key('nav_board')), findsOneWidget);
    expect(find.byKey(const Key('nav_settings')), findsOneWidget);
  });

  testWidgets('the tab badge is hidden when the queue is clear (EMPTY-01)', (
    tester,
  ) async {
    await pumpApp(tester, repo: FakeFeedRepository());

    expect(
      find.descendant(
        of: find.byKey(const Key('nav_needs_you')),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'the tab badge shows the amber dot when decisions wait (HOME-01)',
    (tester) async {
      await pumpApp(
        tester,
        repo: FakeFeedRepository(
          page: FeedPage(rows: [makeRow()], meta: const FeedMeta(count: 1)),
        ),
      );

      final badge = tester.widget<Badge>(
        find
            .descendant(
              of: find.byKey(const Key('nav_needs_you')),
              matching: find.byType(Badge),
            )
            .first,
      );
      expect(badge.backgroundColor, RelayTheme.relayBlocked);
    },
  );

  testWidgets('tapping Board then Settings navigates to those screens', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('nav_board')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stub_board_body')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings_log_out')), findsOneWidget);
  });

  testWidgets(
    'switching from the sheet keeps the tab — Needs you and Settings (RE376)',
    (tester) async {
      await pumpApp(
        tester,
        boardSlug: 'mkt',
        boards: FakeBoardsRepository(
          boards: [
            makeBoard('mkt', name: 'Marketing site'),
            makeBoard('dat', name: 'Data pipeline'),
          ],
        ),
      );

      await tester.tap(find.byKey(const Key('board_switcher_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('board_row_dat')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs_you_header')), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('board_switcher_name'))).data,
        'Data pipeline',
      );

      await tester.tap(find.byKey(const Key('nav_settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('board_switcher_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('board_row_mkt')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings_log_out')), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        2,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('board_switcher_name'))).data,
        'Marketing site',
      );
    },
  );

  testWidgets('the tab dot counts only the current board (RE376)', (
    tester,
  ) async {
    await pumpApp(
      tester,
      boardSlug: 'mkt',
      boards: FakeBoardsRepository(
        boards: [makeBoard('mkt'), makeBoard('dat')],
      ),
      repo: FakeFeedRepository(
        page: FeedPage(
          rows: [makeRow(ref: 'DAT-1', boardKey: 'DAT')],
          meta: const FeedMeta(count: 1),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('nav_needs_you')),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'a switch from the Board tab reloads it onto the new board and stays on Board (RE376)',
    (tester) async {
      await pumpApp(
        tester,
        boardSlug: 'mkt',
        boards: FakeBoardsRepository(
          boards: [makeBoard('mkt'), makeBoard('dat')],
        ),
      );
      await tester.tap(find.byKey(const Key('nav_board')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('board_body_mkt')), findsOneWidget);

      // What the webview's relayOpenBoardSwitcher bridge does.
      unawaited(
        showBoardSwitcherSheet(tester.element(find.byType(BoardScreen))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('board_row_dat')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('board_body_dat')), findsOneWidget);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        1,
      );
    },
  );

  testWidgets(
    'starring from the sheet keeps it open and re-renders in server order (RE396)',
    (tester) async {
      final repo =
          FakeBoardsRepository(
              boards: [
                makeBoard('mkt', name: 'Marketing site'),
                makeBoard('dat', name: 'Data pipeline'),
              ],
            )
            ..onStar = (r) => r.boards = [
              makeBoard('dat', name: 'Data pipeline', starred: true),
              makeBoard('mkt', name: 'Marketing site'),
            ];
      await pumpApp(tester, boardSlug: 'mkt', boards: repo);

      await tester.tap(find.byKey(const Key('board_switcher_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('board_row_star_dat')));
      await tester.pumpAndSettle();

      expect(repo.starCalls, [('dat', true)]);
      expect(find.byKey(const Key('board_switcher_title')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('board_switcher_name'))).data,
        'Marketing site',
      );
      expect(find.byKey(const Key('board_row_current_mkt')), findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('board_row_star_dat')),
                matching: find.byType(Icon),
              ),
            )
            .icon,
        Icons.star,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('board_row_dat'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('board_row_mkt'))).dy),
      );
    },
  );

  testWidgets('muting from the sheet keeps it open on the same board (RE406)', (
    tester,
  ) async {
    final repo =
        FakeBoardsRepository(
            boards: [
              makeBoard('mkt', name: 'Marketing site'),
              makeBoard('dat', name: 'Data pipeline'),
            ],
          )
          ..onMute = (r) => r.boards = [
            makeBoard('mkt', name: 'Marketing site'),
            makeBoard('dat', name: 'Data pipeline', muted: true),
          ];
    await pumpApp(tester, boardSlug: 'mkt', boards: repo);

    await tester.tap(find.byKey(const Key('board_switcher_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('board_row_mute_dat')));
    await tester.pumpAndSettle();

    expect(repo.muteCalls, [('dat', true)]);
    expect(find.byKey(const Key('board_row_current_mkt')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('board_switcher_name'))).data,
      'Marketing site',
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const Key('board_row_mute_dat')),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      Icons.notifications_off_outlined,
    );
  });
}
