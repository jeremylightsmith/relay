import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository;

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
        routerConfig: buildRouter(),
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

  testWidgets('Needs you destination carries the amber notification dot', (
    tester,
  ) async {
    await pumpApp(tester);
    final badge = tester.widget<Badge>(
      find
          .descendant(
            of: find.byKey(const Key('nav_needs_you')),
            matching: find.byType(Badge),
          )
          .first,
    );
    expect(badge.backgroundColor, RelayTheme.relayBlocked);
  });

  testWidgets('tapping Board then Settings navigates to those screens', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const Key('nav_board')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Board'), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_settings')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
  });
}
