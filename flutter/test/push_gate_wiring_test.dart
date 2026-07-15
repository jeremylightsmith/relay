// The "Not now" wiring: tapping AUTH-03's secondary CTA must record the deferral,
// or the §1 cooldown never engages and we re-prime every launch (RLY-84).
//
// Overriding pushOnboardingProvider is the seam here: the route builder reads the
// gate from `ref`, so there is no constructor to inject through. The value is
// still a hand-written fake, not a mock.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/features/push/push_onboarding.dart';
import 'package:relay_mobile/features/push/push_platform.dart';
import 'package:relay_mobile/features/push/push_service.dart';

import 'support/fake_push.dart';

void main() {
  testWidgets('"Not now" defers priming and lands on Needs you', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 7, 14, 12);
    final prefs = FakePushPrefs();
    final platform = FakePushPlatform(
      status: PushAuthorizationStatus.notDetermined,
    );
    final gate = PushOnboarding(
      platform: platform,
      service: PushService(
        platform: platform,
        dio: dioWith(RecordingAdapter()),
      ),
      prefs: prefs,
      clock: () => now,
    );

    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pushOnboardingProvider.overrideWithValue(gate)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    router.go('/push-permission');
    await tester.pumpAndSettle();
    expect(find.text('Let Relay reach you'), findsOneWidget);

    await tester.tap(find.byKey(const Key('push_skip')));
    await tester.pumpAndSettle();

    // The deferral is recorded…
    expect(prefs.deferredAt, now);
    expect(prefs.writeCount, 1);
    // …and the user lands in the shell on Needs you. Keyed on the in-page header
    // rather than an AppBar: RLY-85 replaced the AppBar with HOME-01's header.
    expect(find.byKey(const Key('needs_you_header')), findsOneWidget);
  });
}
