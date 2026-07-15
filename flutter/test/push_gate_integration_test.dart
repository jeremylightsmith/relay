// The AUTH-03 gate, driven through the REAL router (RLY-84 · §1).
//
// This is the test that matters, and the one push_gate_wiring_test cannot be:
// that one calls `buildRouter()` with no `redirect`, so it never exercises
// `routerProvider`'s redirect — which is what actually decides whether AUTH-03
// is shown (RLY-86 §6). A gate that `resolve()`s to `skip` is worthless if the
// redirect routes to /push-permission anyway, and only booting the real app
// catches that.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/push/push_platform.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:relay_mobile/main.dart';

import 'support/fake_auth.dart';
import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';
import 'support/recording_adapter.dart';

/// The real gated app (routerProvider + RLY-86's redirect), with auth scripted
/// and the push platform/prefs faked. Mirrors deep_link_resume_test's harness.
Future<(ScriptedAuthController, RecordingAdapter)> pumpLaunch(
  WidgetTester tester, {
  required PushAuthorizationStatus status,
  DateTime? deferredAt,
  String? authorizedToken,
}) async {
  final auth = ScriptedAuthController();
  final adapter = RecordingAdapter();
  final platform = FakePushPlatform(
    status: status,
    authorizedToken: authorizedToken,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        pushPlatformProvider.overrideWithValue(platform),
        pushPrefsProvider.overrideWithValue(
          FakePushPrefs(deferredAt: deferredAt),
        ),
        pushServiceProvider.overrideWith(
          (ref) => PushService(platform: platform, dio: dioWith(adapter)),
        ),
        cardBodyBuilderProvider.overrideWithValue(
          (_) => const SizedBox.shrink(key: Key('stub_card_body')),
        ),
      ],
      child: const RelayApp(),
    ),
  );
  await tester.pump();
  return (auth, adapter);
}

/// Drive the two-step interactive sign-in and let the redirect settle.
Future<void> signIn(WidgetTester tester, ScriptedAuthController auth) async {
  auth.resolve(const AuthState(status: AuthStatus.signedOut));
  await tester.pump();
  await auth.signInWithGoogle();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'an interactive sign-in does not prime AUTH-03 once iOS has denied',
    (tester) async {
      final (auth, _) = await pumpLaunch(
        tester,
        status: PushAuthorizationStatus.denied,
      );

      await signIn(tester, auth);

      // iOS will never show the prompt again, so AUTH-03 could only lie about what
      // its button does. Land on the inbox instead.
      expect(
        find.text('Let Relay reach you'),
        findsNothing,
        reason: 'AUTH-03 primed even though the OS has permanently denied push',
      );
      expect(find.byKey(const Key('needs_you_header')), findsOneWidget);
    },
  );

  testWidgets('an interactive sign-in still primes AUTH-03 when undecided', (
    tester,
  ) async {
    final (auth, _) = await pumpLaunch(
      tester,
      status: PushAuthorizationStatus.notDetermined,
    );

    await signIn(tester, auth);

    // The one-shot OS prompt is unspent — priming is exactly what AUTH-03 is for.
    expect(find.text('Let Relay reach you'), findsOneWidget);
  });

  testWidgets('an interactive sign-in does not re-prime within the cooldown', (
    tester,
  ) async {
    final (auth, _) = await pumpLaunch(
      tester,
      status: PushAuthorizationStatus.notDetermined,
      deferredAt: DateTime.now().subtract(const Duration(days: 1)),
    );

    await signIn(tester, auth);

    // "Not now" a day ago. Don't nag.
    expect(
      find.text('Let Relay reach you'),
      findsNothing,
      reason: 'AUTH-03 re-primed one day after the user tapped "Not now"',
    );
    expect(find.byKey(const Key('needs_you_header')), findsOneWidget);
  });

  testWidgets(
    'an interactive sign-in primes again once the cooldown has lapsed',
    (tester) async {
      final (auth, _) = await pumpLaunch(
        tester,
        status: PushAuthorizationStatus.notDetermined,
        deferredAt: DateTime.now().subtract(const Duration(days: 8)),
      );

      await signIn(tester, auth);

      expect(find.text('Let Relay reach you'), findsOneWidget);
    },
  );

  testWidgets(
    'an already-authorized sign-in skips AUTH-03 and re-registers the token',
    (tester) async {
      final (auth, adapter) = await pumpLaunch(
        tester,
        status: PushAuthorizationStatus.authorized,
        authorizedToken: 'apns-tok-123',
      );

      await signIn(tester, auth);

      expect(
        find.text('Let Relay reach you'),
        findsNothing,
        reason: 'AUTH-03 primed at a user who has already allowed push',
      );
      // §2: the skip is only half of it. RLY-81 registers the token on the "Allow"
      // tap alone, so once we stop showing AUTH-03 this is the only thing keeping
      // the device registered — the silent regression this card exists to prevent.
      expect(
        adapter.requests.where((r) => r.path == '/api/all/devices'),
        isNotEmpty,
        reason: 'skipped AUTH-03 without re-registering — push dies silently',
      );
    },
  );
}
