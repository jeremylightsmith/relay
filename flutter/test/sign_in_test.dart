import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/sign_in_screen.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'support/fake_auth.dart';

Future<FakeAuthController> pumpSignIn(
  WidgetTester tester, {
  AuthState seed = const AuthState(status: AuthStatus.signedOut),
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

final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);
final _android = TargetPlatformVariant.only(TargetPlatform.android);
const _google = Key('sign_in_google');
const _apple = Key('sign_in_apple');

SignInWithAppleButton appleButton(WidgetTester tester) =>
    tester.widget<SignInWithAppleButton>(find.byKey(_apple));

/// The nearest wrapper of [type] around the Apple button — the package's button
/// has no disabled state, so the screen fakes one with IgnorePointer + Opacity.
T appleWrapper<T extends Widget>(WidgetTester tester) => tester.widget<T>(
  find.ancestor(of: find.byKey(_apple), matching: find.byType(T)).first,
);

void main() {
  testWidgets('on iOS, offers Google plus the official Apple button', (
    tester,
  ) async {
    await pumpSignIn(tester);

    final google = tester.widget<OutlinedButton>(find.byKey(_google));
    expect(google.onPressed, isNotNull);
    expect(find.text('Continue with Google'), findsOneWidget);

    expect(find.byKey(_apple), findsOneWidget);
    final apple = appleButton(tester);
    expect(apple.text, 'Continue with Apple');
    expect(apple.style, SignInWithAppleButtonStyle.black);
    expect(apple.borderRadius, const BorderRadius.all(Radius.circular(11)));

    // Below Google, 9px apart.
    final googleRect = tester.getRect(find.byKey(_google));
    final appleRect = tester.getRect(find.byKey(_apple));
    expect(appleRect.top, greaterThan(googleRect.bottom));
    expect(appleRect.top - googleRect.bottom, 9);

    expect(find.textContaining('(soon)'), findsNothing);
  }, variant: _ios);

  testWidgets('on iOS in dark mode, the Apple button is white', (tester) async {
    await pumpSignIn(tester, theme: RelayTheme.dark);

    expect(appleButton(tester).style, SignInWithAppleButtonStyle.white);
  }, variant: _ios);

  testWidgets('on iOS, the Apple button is exactly as tall as Google', (
    tester,
  ) async {
    await pumpSignIn(tester);

    final googleHeight = tester.getSize(find.byKey(_google)).height;
    expect(googleHeight, tester.getSize(find.byKey(_apple)).height);
    // …and as tall as Google's drawn surface, not just its layout box.
    final googleSurface = find
        .descendant(of: find.byKey(_google), matching: find.byType(Material))
        .first;
    expect(tester.getSize(googleSurface).height, googleHeight);
  }, variant: _ios);

  testWidgets('on Android there is no Apple button', (tester) async {
    await pumpSignIn(tester);

    expect(find.byKey(_apple), findsNothing);
    expect(find.byKey(_google), findsOneWidget);
  }, variant: _android);

  testWidgets('tapping Apple signs in with Apple, not Google', (tester) async {
    final fake = await pumpSignIn(tester);

    await tester.tap(find.byKey(_apple));
    await tester.pump();

    expect(fake.appleSignInCalls, 1);
    expect(fake.signInCalls, 0);
  }, variant: _ios);

  testWidgets('while Apple is signing in, both providers are disabled and '
      'Google keeps its label', (tester) async {
    final fake = await pumpSignIn(
      tester,
      seed: const AuthState(
        status: AuthStatus.signingIn,
        method: SignInMethod.apple,
      ),
    );

    expect(
      tester.widget<OutlinedButton>(find.byKey(_google)).onPressed,
      isNull,
    );
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Signing in…'), findsNothing);

    expect(appleWrapper<IgnorePointer>(tester).ignoring, isTrue);
    expect(appleWrapper<Opacity>(tester).opacity, 0.38);

    await tester.tap(find.byKey(_apple), warnIfMissed: false);
    await tester.pump();
    expect(fake.appleSignInCalls, 0);
  }, variant: _ios);

  testWidgets('signed out on iOS, the Apple button is live and opaque', (
    tester,
  ) async {
    await pumpSignIn(tester);

    expect(appleWrapper<IgnorePointer>(tester).ignoring, isFalse);
    expect(appleWrapper<Opacity>(tester).opacity, 1.0);
  }, variant: _ios);

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
  });

  testWidgets('while Google is signing in, it is disabled and says so', (
    tester,
  ) async {
    await pumpSignIn(
      tester,
      seed: const AuthState(
        status: AuthStatus.signingIn,
        method: SignInMethod.google,
      ),
    );

    final google = tester.widget<OutlinedButton>(find.byKey(_google));
    expect(google.onPressed, isNull);
    expect(find.text('Signing in…'), findsOneWidget);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('while Google is signing in on iOS, Apple is disabled too', (
    tester,
  ) async {
    await pumpSignIn(
      tester,
      seed: const AuthState(
        status: AuthStatus.signingIn,
        method: SignInMethod.google,
      ),
    );

    expect(
      tester.widget<OutlinedButton>(find.byKey(_google)).onPressed,
      isNull,
    );
    expect(find.text('Signing in…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(appleWrapper<IgnorePointer>(tester).ignoring, isTrue);
  }, variant: _ios);

  testWidgets('a failure shows the friendly message and a working retry', (
    tester,
  ) async {
    const message = 'Something went wrong signing you in. Please try again.';
    final fake = await pumpSignIn(
      tester,
      seed: const AuthState(
        status: AuthStatus.signedOut,
        error: message,
        method: SignInMethod.google,
      ),
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
    expect(fake.appleSignInCalls, 0);
  });

  testWidgets('a failed Apple sign-in retries with Apple', (tester) async {
    const message = "Relay couldn't sign you in with that Apple ID.";
    final fake = await pumpSignIn(
      tester,
      seed: const AuthState(
        status: AuthStatus.signedOut,
        error: message,
        method: SignInMethod.apple,
      ),
    );

    await tester.tap(find.byKey(const Key('sign_in_retry')));
    await tester.pumpAndSettle();
    expect(fake.appleSignInCalls, 1);
    expect(fake.signInCalls, 0);
  }, variant: _ios);

  testWidgets('with no error, no error container is rendered', (tester) async {
    await pumpSignIn(tester);

    expect(find.byKey(const Key('sign_in_error')), findsNothing);
    expect(find.byKey(const Key('sign_in_retry')), findsNothing);
  });
}
