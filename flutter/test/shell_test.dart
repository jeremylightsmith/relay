import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;

/// The tab shell in isolation (ungated). The auth gate is exercised separately in
/// auth_test.dart; here we assert the three-tab shell itself. The inbox's repository
/// is faked — the shell watches the feed count for its badge (D6), so pumping the
/// shell would otherwise fire a real request.
Future<void> pumpApp(WidgetTester tester, {FakeFeedRepository? repo}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
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
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
  });
}
