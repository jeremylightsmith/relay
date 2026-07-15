// The RLY-84 §1 gating matrix, one test per row. The fixed clock makes the 7-day
// cooldown deterministic.
//
// `resolve()` is a *decision*, so these tests assert only the decision. The other
// half of the skip — silently re-registering the token (§2) — is main.dart's,
// keyed on a session going live so it also covers the restored sessions that
// never reach this gate; it is asserted in push_gate_integration_test.
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/push/push_onboarding.dart';
import 'package:relay_mobile/features/push/push_platform.dart';

import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';

final now = DateTime.utc(2026, 7, 14, 12);

/// The gate plus the collaborators a test needs to assert against.
class Harness {
  Harness({
    required PushAuthorizationStatus status,
    String? authorizedToken = 'apns-tok-123',
    DateTime? deferredAt,
    Object? statusError,
  }) : platform = FakePushPlatform(
         status: status,
         authorizedToken: authorizedToken,
         statusError: statusError,
       ),
       prefs = FakePushPrefs(deferredAt: deferredAt) {
    gate = PushOnboarding(platform: platform, prefs: prefs, clock: () => now);
  }

  final FakePushPlatform platform;
  final FakePushPrefs prefs;
  late final PushOnboarding gate;
}

void main() {
  test('notDetermined with no deferral primes AUTH-03', () async {
    final h = Harness(status: PushAuthorizationStatus.notDetermined);

    expect(await h.gate.resolve(), PushGateDecision.prime);
  });

  test('notDetermined deferred 1 day ago skips (do not nag)', () async {
    final h = Harness(
      status: PushAuthorizationStatus.notDetermined,
      deferredAt: now.subtract(const Duration(days: 1)),
    );

    expect(await h.gate.resolve(), PushGateDecision.skip);
  });

  test('notDetermined deferred 8 days ago primes once more', () async {
    final h = Harness(
      status: PushAuthorizationStatus.notDetermined,
      deferredAt: now.subtract(const Duration(days: 8)),
    );

    expect(await h.gate.resolve(), PushGateDecision.prime);
  });

  for (final status in const [
    PushAuthorizationStatus.authorized,
    PushAuthorizationStatus.provisional,
    PushAuthorizationStatus.ephemeral,
  ]) {
    test('$status skips — the decision is already made', () async {
      final h = Harness(status: status);

      expect(await h.gate.resolve(), PushGateDecision.skip);
      // Silently: deciding must never surface an OS prompt.
      expect(h.platform.requestCount, 0);
    });
  }

  test('denied skips and never prompts', () async {
    final h = Harness(status: PushAuthorizationStatus.denied);

    expect(await h.gate.resolve(), PushGateDecision.skip);
    expect(h.platform.requestCount, 0);
    expect(h.platform.tokenIfAuthorizedCount, 0);
  });

  test('an unavailable status skips instead of throwing', () async {
    final h = Harness(
      status: PushAuthorizationStatus.notDetermined,
      statusError: StateError('unknown push authorization status: null'),
    );

    // Fail safe: never show a screen whose button we cannot back up, and never
    // throw out of the gate — push is best-effort and must not break sign-in.
    expect(await h.gate.resolve(), PushGateDecision.skip);
  });

  test(
    'resolving does not register anything — that is main.dart\'s job',
    () async {
      final h = Harness(status: PushAuthorizationStatus.authorized);

      await h.gate.resolve();

      // The gate has no PushService at all now; asserting the platform seam stays
      // untouched is what keeps the responsibility from drifting back here.
      expect(h.platform.tokenIfAuthorizedCount, 0);
    },
  );

  test('deferPriming writes the clock\'s now', () async {
    final h = Harness(status: PushAuthorizationStatus.notDetermined);

    await h.gate.deferPriming();

    expect(h.prefs.deferredAt, now);
    expect(h.prefs.writeCount, 1);
  });
}
