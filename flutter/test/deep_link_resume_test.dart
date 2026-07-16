import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:relay_mobile/main.dart';

import 'support/fake_auth.dart';
import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';

const _cardPush = {
  'card_ref': 'RLY-1',
  'board_slug': 'b1',
  'kind': 'needs_input',
};

/// The real gated app (routerProvider + its redirect), with auth scripted and the
/// card body stubbed — flutter_inappwebview has no host-platform implementation.
///
/// Returns both the auth controller (to script auth transitions) and the push
/// platform (to drive `tapHandler` — the *warm* tap path — directly).
Future<(ScriptedAuthController, FakePushPlatform)> pumpLaunch(
  WidgetTester tester, {
  Map<String, dynamic>? coldNotification,
}) async {
  final auth = ScriptedAuthController();
  final platform = FakePushPlatform()..initial = coldNotification;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        pushPlatformProvider.overrideWithValue(platform),
        // /push-permission gates itself on the OS status + deferral (RLY-84 §1).
        // Fake the prefs seam or the gate reads a real IosPushPrefs over an
        // unmocked MethodChannel, throws, and fail-safes to skip — which would
        // silently defeat this file's "primes push permission" assertion.
        pushPrefsProvider.overrideWithValue(FakePushPrefs()),
        cardBodyBuilderProvider.overrideWithValue(
          (_) => const SizedBox.shrink(key: Key('stub_card_body')),
        ),
      ],
      child: const RelayApp(),
    ),
  );
  // pump(), not pumpAndSettle(): the splash's indeterminate progress indicator
  // schedules frames forever, so settling *on* the splash would time out.
  await tester.pump();
  return (auth, platform);
}

void main() {
  testWidgets('while auth is restoring, the app holds on the splash', (
    tester,
  ) async {
    await pumpLaunch(tester);

    expect(find.byKey(const Key('splash_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('welcome_screen')),
      findsNothing,
      reason: 'bouncing to Welcome before the Keychain read returns is the bug',
    );
  });

  testWidgets('a restored session resumes the launch destination, and does '
      'not prime push permission', (tester) async {
    final (auth, _) = await pumpLaunch(tester);

    auth.resolve(
      const AuthState(
        status: AuthStatus.signedIn,
        user: {'email': 'd@acme.co'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(
      find.text('Let Relay reach you'),
      findsNothing,
      reason:
          'AUTH-03 primes after an interactive sign-in, not on every cold start',
    );
  });

  testWidgets(
    'a cold-start push tap lands on the card once the session restores',
    (tester) async {
      final (auth, _) = await pumpLaunch(tester, coldNotification: _cardPush);
      // Let _wirePush read the cold notification and fire it at the router.
      await tester.pump();

      auth.resolve(
        const AuthState(
          status: AuthStatus.signedIn,
          user: {'email': 'd@acme.co'},
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<CardScreen>(find.byType(CardScreen)).cardRef,
        'RLY-1',
      );
    },
  );

  testWidgets(
    'with no session, the card is held through sign-in and resumed after',
    (tester) async {
      final (auth, _) = await pumpLaunch(tester, coldNotification: _cardPush);
      await tester.pump();

      auth.resolve(const AuthState(status: AuthStatus.signedOut));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('welcome_screen')), findsOneWidget);

      await tester.tap(find.byKey(const Key('welcome_sign_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign_in_google')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<CardScreen>(find.byType(CardScreen)).cardRef,
        'RLY-1',
        reason:
            'the whole point of the card: sign-in must not eat the deep link',
      );
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets(
    'an interactive sign-in with no deep link primes push permission',
    (tester) async {
      final (auth, _) = await pumpLaunch(tester);

      auth.resolve(const AuthState(status: AuthStatus.signedOut));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('welcome_sign_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign_in_google')));
      await tester.pumpAndSettle();

      expect(find.text('Let Relay reach you'), findsOneWidget);
    },
  );

  testWidgets(
    'a warm push tap while signed out is held through sign-in and resumed after',
    (tester) async {
      final (auth, platform) = await pumpLaunch(tester);

      auth.resolve(const AuthState(status: AuthStatus.signedOut));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('welcome_screen')), findsOneWidget);

      // Warm: a tap while the app is already running, sitting on Welcome —
      // distinct from the cold-notification path exercised above.
      platform.tapHandler!(_cardPush);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('welcome_sign_in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('sign_in_google')));
      await tester.pumpAndSettle();

      expect(
        tester.widget<CardScreen>(find.byType(CardScreen)).cardRef,
        'RLY-1',
        reason:
            'a warm tap while signed out must not be eaten by sign-in or '
            'the AUTH-03 permission prime either',
      );
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets('signing out from Account does not arm the deep-link resume', (
    tester,
  ) async {
    final (auth, _) = await pumpLaunch(tester);
    auth.resolve(
      const AuthState(
        status: AuthStatus.signedIn,
        user: {'email': 'd@acme.co'},
      ),
    );
    await tester.pumpAndSettle();

    // Settings → Account, then sign out from there (what the confirm's
    // Log out button does via signOut()).
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings_account_row')));
    await tester.pumpAndSettle();
    auth.resolve(const AuthState(status: AuthStatus.signedOut));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('welcome_screen')), findsOneWidget);

    // Sign back in: land on the inbox — NOT back on Account. Without the
    // justSignedOut flag, the redirect stashes /account as a pending deep
    // link the moment the sign-out redirect runs, and sign-in resumes it.
    auth.resolve(
      const AuthState(
        status: AuthStatus.signedIn,
        user: {'email': 'd@acme.co'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Account'), findsNothing);
    // back in the tab shell at the default landing (pumpLaunch does not fake
    // the feed, so assert the shell rather than the inbox's loaded state)
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
