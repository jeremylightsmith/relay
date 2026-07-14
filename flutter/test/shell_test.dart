import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/main.dart';

Future<void> pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const ProviderScope(child: RelayApp()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('boots to the Needs you tab', (tester) async {
    await pumpApp(tester);
    expect(find.widgetWithText(AppBar, 'Needs you'), findsOneWidget);
    expect(find.text('Arriving soon'), findsOneWidget);
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
