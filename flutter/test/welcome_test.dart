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

    expect(find.text('Welcome to hammock driven development.'), findsOneWidget);
    expect(find.text('Pass work between people and AI.'), findsNothing);
    expect(
      find.text('One board, one thread. Hamaca keeps the handoff clear.'),
      findsOneWidget,
    );
    // Decision 2: signing in with Google *is* signing up.
    expect(find.text('Create account'), findsNothing);
  });

  testWidgets('shows the Hamaca colour mark from the branding asset', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    final mark = find.byKey(const Key('welcome_mark'));
    expect(mark, findsOneWidget);
    final image = tester.widget<Image>(mark).image;
    expect(image, isA<AssetImage>());
    expect((image as AssetImage).assetName, WelcomeScreen.markAsset);
    expect(WelcomeScreen.markAsset, 'assets/branding/hamaca_mark.png');
  });

  testWidgets('the mark renders at the mockup\'s 112×112 (w-28)', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    expect(
      tester.getSize(find.byKey(const Key('welcome_mark'))),
      const Size(112, 112),
    );
  });

  testWidgets('the blue placeholder tile is gone', (tester) async {
    await pumpSignedOutApp(tester);

    expect(find.byIcon(Icons.circle), findsNothing);
  });

  testWidgets('the mark sits 20px above the headline, 12px left of it', (
    tester,
  ) async {
    await pumpSignedOutApp(tester);

    final mark = find.byKey(const Key('welcome_mark'));
    final headline = find.text('Welcome to hammock driven development.');
    expect(
      tester.getBottomLeft(mark).dy + 20,
      moreOrLessEquals(tester.getTopLeft(headline).dy, epsilon: 0.5),
    );
    expect(
      tester.getTopLeft(mark).dx,
      moreOrLessEquals(tester.getTopLeft(headline).dx - 12, epsilon: 0.5),
    );
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
