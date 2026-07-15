// AUTH-03 "Enable push" — docs/designs/Relay Mobile.dc.html lines ~99–117.
// The concrete values below are pinned to that artboard; change them only when
// the mockup changes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/push/push_permission_screen.dart';

Future<void> pumpScreen(
  WidgetTester tester, {
  VoidCallback? onAllow,
  VoidCallback? onSkip,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: PushPermissionScreen(
        onAllow: onAllow ?? () {},
        onSkip: onSkip ?? () {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('matches AUTH-03 headline and body copy', (tester) async {
    await pumpScreen(tester);

    expect(find.text('Let Relay reach you'), findsOneWidget);
    expect(
      find.text(
        "The AI works while you're away. Notifications are how it tells you "
        'the moment it needs a decision.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('headline uses the mockup 20px/600 type', (tester) async {
    await pumpScreen(tester);

    final headline = tester.widget<Text>(find.text('Let Relay reach you'));
    expect(headline.style?.fontSize, 20);
    expect(headline.style?.fontWeight, FontWeight.w600);
  });

  testWidgets('primary CTA is the blue "Allow notifications" button', (
    tester,
  ) async {
    await pumpScreen(tester);

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('push_allow')),
    );
    expect(
      button.style?.backgroundColor?.resolve({}),
      RelayTheme.relayHuman, // oklch(0.60 0.14 250) — mockup line 113
    );
    expect(find.text('Allow notifications'), findsOneWidget);
  });

  testWidgets('secondary CTA is a transparent "Not now"', (tester) async {
    await pumpScreen(tester);

    expect(find.byKey(const Key('push_skip')), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('the bell icon carries the amber dot', (tester) async {
    await pumpScreen(tester);

    final dot = tester.widget<Container>(
      find.byKey(const Key('push_icon_dot')),
    );
    expect((dot.decoration as BoxDecoration).color, RelayTheme.relayBlocked);
  });

  testWidgets('Allow fires onAllow; Not now fires onSkip', (tester) async {
    var allowed = false;
    var skipped = false;
    await pumpScreen(
      tester,
      onAllow: () => allowed = true,
      onSkip: () => skipped = true,
    );

    await tester.tap(find.byKey(const Key('push_allow')));
    await tester.pumpAndSettle();
    expect(allowed, isTrue);

    await tester.tap(find.byKey(const Key('push_skip')));
    await tester.pumpAndSettle();
    expect(skipped, isTrue);
  });
}
