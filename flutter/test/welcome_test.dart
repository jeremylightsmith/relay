import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/welcome_screen.dart';
import 'package:relay_mobile/main.dart';

import 'support/fake_auth.dart';

Future<void> pumpSignedOutApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(FakeAuthController.new)],
      child: const RelayApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every LinearGradient currently painted, so we can assert the brand gradient
/// without adding a test-only key to the widget tree.
Iterable<LinearGradient> paintedGradients(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(find.byType(DecoratedBox))
    .map((box) => box.decoration)
    .whereType<BoxDecoration>()
    .map((decoration) => decoration.gradient)
    .whereType<LinearGradient>();

void main() {
  testWidgets('a signed-out launch lands on Welcome, not straight on Sign in', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    expect(find.byKey(const Key('welcome_screen')), findsOneWidget);
    expect(find.byKey(const Key('sign_in_google')), findsNothing);
  });

  testWidgets('shows the brand headline and no Create account button', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    expect(find.text('Pass work between people and AI.'), findsOneWidget);
    expect(
      find.text('One board, one thread. Relay keeps the handoff clear.'),
      findsOneWidget,
    );
    // Decision 2: signing in with Google *is* signing up.
    expect(find.text('Create account'), findsNothing);
  });

  testWidgets('AUTH-01 gradient · #23375C → #0D1624 at 165°', (tester) async {
    await pumpSignedOutApp(tester);

    expect(WelcomeScreen.gradient.colors, [
      const Color(0xFF23375C),
      const Color(0xFF0D1624),
    ]);
    expect(paintedGradients(tester), contains(WelcomeScreen.gradient));
  });

  testWidgets('the brand gradient is identical in dark mode', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await pumpSignedOutApp(tester);

    expect(paintedGradients(tester), contains(WelcomeScreen.gradient));
  });

  testWidgets('the Sign in button matches AUTH-01 · blue fill, 13px radius', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    final button = tester.widget<FilledButton>(
      find.byKey(const Key('welcome_sign_in')),
    );
    final style = button.style!;
    expect(style.backgroundColor!.resolve({}), const Color(0xFF3284D0));
    expect(style.foregroundColor!.resolve({}), Colors.white);
    expect(
      style.shape!.resolve({}),
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
    );
  });

  testWidgets('Sign in pushes AUTH-02, and back returns to Welcome', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    await tester.tap(find.byKey(const Key('welcome_sign_in')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_in_google')), findsOneWidget);
    expect(find.byKey(const Key('welcome_screen')), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome_screen')), findsOneWidget);
    expect(find.byKey(const Key('sign_in_google')), findsNothing);
  });
}
