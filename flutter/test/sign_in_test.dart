import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/sign_in_screen.dart';

import 'support/fake_auth.dart';

Future<FakeAuthController> pumpSignIn(
  WidgetTester tester, {
  AuthState seed = const AuthState(),
  ThemeData? theme,
}) async {
  final fake = FakeAuthController(seed);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(() => fake)],
      child: MaterialApp(
        theme: theme ?? RelayTheme.light,
        home: const SignInScreen(),
      ),
    ),
  );
  // pump(), not pumpAndSettle(): the signingIn:true seed renders an
  // indeterminate CircularProgressIndicator, whose repeating animation
  // schedules frames forever and would make pumpAndSettle time out.
  await tester.pump();
  return fake;
}

void main() {
  testWidgets('offers exactly two providers: Google live, Apple disabled', (
    tester,
  ) async {
    await pumpSignIn(tester);

    final google = tester.widget<OutlinedButton>(
      find.byKey(const Key('sign_in_google')),
    );
    expect(google.onPressed, isNotNull);
    expect(find.text('Continue with Google'), findsOneWidget);

    final apple = tester.widget<FilledButton>(
      find.byKey(const Key('sign_in_apple')),
    );
    expect(apple.onPressed, isNull, reason: 'Apple lands in RLY-106');
    expect(find.text('Sign in with Apple (soon)'), findsOneWidget);
  });

  testWidgets('ships no control the backend cannot honour', (tester) async {
    await pumpSignIn(tester);

    expect(find.text('Continue with GitHub'), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text('or'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('AUTH-02 title · left-aligned, 23px w600, #141B24 in light', (
    tester,
  ) async {
    await pumpSignIn(tester);

    final title = tester.widget<Text>(find.text('Sign in'));
    expect(title.style!.fontSize, 23);
    expect(title.style!.fontWeight, FontWeight.w600);
    expect(title.style!.letterSpacing, -0.575); // -0.025em at 23px
    expect(title.style!.color, const Color(0xFF141B24));
  });

  testWidgets('the title stays readable in dark mode', (tester) async {
    await pumpSignIn(tester, theme: RelayTheme.dark);

    final title = tester.widget<Text>(find.text('Sign in'));
    expect(title.style!.color, RelayTheme.dark.colorScheme.onSurface);
    expect(title.style!.color, isNot(const Color(0xFF141B24)));
  });

  testWidgets('AUTH-02 provider buttons · 11px radius, artboard fills', (
    tester,
  ) async {
    await pumpSignIn(tester);

    final expectedShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
    );

    final google = tester
        .widget<OutlinedButton>(find.byKey(const Key('sign_in_google')))
        .style!;
    expect(google.shape!.resolve({}), expectedShape);
    expect(google.backgroundColor!.resolve({}), Colors.white);
    expect(google.foregroundColor!.resolve({}), const Color(0xFF272E38));
    expect(google.side!.resolve({})!.color, const Color(0xFFD5D8DB));

    final apple = tester
        .widget<FilledButton>(find.byKey(const Key('sign_in_apple')))
        .style!;
    expect(apple.shape!.resolve({}), expectedShape);
    // Disabled, but still the artboard's dark second-provider slot.
    expect(
      apple.backgroundColor!.resolve({WidgetState.disabled}),
      const Color(0xFF13161B).withValues(alpha: 0.38),
    );
  });

  testWidgets('while signing in, Google is disabled and says so', (
    tester,
  ) async {
    await pumpSignIn(tester, seed: const AuthState(signingIn: true));

    final google = tester.widget<OutlinedButton>(
      find.byKey(const Key('sign_in_google')),
    );
    expect(google.onPressed, isNull);
    expect(find.text('Signing in…'), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a failure shows the friendly message and a working retry', (
    tester,
  ) async {
    const message = 'Something went wrong signing you in. Please try again.';
    final fake = await pumpSignIn(
      tester,
      seed: const AuthState(error: message),
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('sign_in_error')),
        matching: find.text(message),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sign_in_retry')), findsOneWidget);

    // The error is not a dead end: Google stays tappable too.
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('sign_in_google')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('sign_in_retry')));
    await tester.pumpAndSettle();
    expect(fake.signInCalls, 1);
  });

  testWidgets('with no error, no error container is rendered', (tester) async {
    await pumpSignIn(tester);

    expect(find.byKey(const Key('sign_in_error')), findsNothing);
    expect(find.byKey(const Key('sign_in_retry')), findsNothing);
  });
}
