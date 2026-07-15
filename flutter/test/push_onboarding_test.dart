// The RLY-84 §1 gating matrix, one test per row. The fixed clock makes the 7-day
// cooldown deterministic.
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/push/push_onboarding.dart';
import 'package:relay_mobile/features/push/push_platform.dart';
import 'package:relay_mobile/features/push/push_service.dart';

import 'support/fake_push.dart';

final now = DateTime.utc(2026, 7, 14, 12);

/// The gate plus the collaborators a test needs to assert against.
class Harness {
  Harness({
    required PushAuthorizationStatus status,
    String? authorizedToken = 'apns-tok-123',
    DateTime? deferredAt,
    Object? statusError,
    int registerStatusCode = 201,
  }) : platform = FakePushPlatform(
         status: status,
         authorizedToken: authorizedToken,
         statusError: statusError,
       ),
       adapter = RecordingAdapter(statusCode: registerStatusCode),
       prefs = FakePushPrefs(deferredAt: deferredAt) {
    gate = PushOnboarding(
      platform: platform,
      service: PushService(platform: platform, dio: dioWith(adapter)),
      prefs: prefs,
      clock: () => now,
    );
  }

  final FakePushPlatform platform;
  final RecordingAdapter adapter;
  final FakePushPrefs prefs;
  late final PushOnboarding gate;
}

void main() {
  test('notDetermined with no deferral primes AUTH-03', () async {
    final h = Harness(status: PushAuthorizationStatus.notDetermined);

    expect(await h.gate.resolve(), PushGateDecision.prime);
    // Priming must not register anything — the user has not decided yet.
    expect(h.adapter.requests, isEmpty);
  });

  test('notDetermined deferred 1 day ago skips (do not nag)', () async {
    final h = Harness(
      status: PushAuthorizationStatus.notDetermined,
      deferredAt: now.subtract(const Duration(days: 1)),
    );

    expect(await h.gate.resolve(), PushGateDecision.skip);
  });

  test('notDetermined deferred 8 days ago primes again', () async {
    final h = Harness(
      status: PushAuthorizationStatus.notDetermined,
      deferredAt: now.subtract(const Duration(days: 8)),
    );

    expect(await h.gate.resolve(), PushGateDecision.prime);
  });

  test(
    'the cooldown boundary is inclusive: exactly 7 days ago primes',
    () async {
      final h = Harness(
        status: PushAuthorizationStatus.notDetermined,
        deferredAt: now.subtract(PushOnboarding.primingCooldown),
      );

      expect(await h.gate.resolve(), PushGateDecision.prime);
    },
  );

  test('authorized skips AND silently re-registers the token', () async {
    final h = Harness(status: PushAuthorizationStatus.authorized);

    expect(await h.gate.resolve(), PushGateDecision.skip);

    // §2. This POST is the whole reason skipping is safe: without it, a
    // previously-authorized device silently stops being registered.
    expect(h.adapter.requests.single.method, 'POST');
    expect(h.adapter.requests.single.path, '/api/all/devices');
    expect(h.adapter.requests.single.data, {
      'token': 'apns-tok-123',
      'platform': 'ios',
    });

    // Silently: no OS prompt.
    expect(h.platform.requestCount, 0);
  });

  for (final status in const [
    PushAuthorizationStatus.provisional,
    PushAuthorizationStatus.ephemeral,
  ]) {
    test('$status skips and silently re-registers', () async {
      final h = Harness(status: status);

      expect(await h.gate.resolve(), PushGateDecision.skip);
      expect(h.adapter.requests, hasLength(1));
      expect(h.platform.requestCount, 0);
    });
  }

  test('denied skips, registers nothing, and never prompts', () async {
    final h = Harness(status: PushAuthorizationStatus.denied);

    expect(await h.gate.resolve(), PushGateDecision.skip);
    expect(h.adapter.requests, isEmpty);
    expect(h.platform.requestCount, 0);
    expect(h.platform.tokenIfAuthorizedCount, 0);
  });

  test('an unavailable status skips instead of throwing', () async {
    final h = Harness(
      status: PushAuthorizationStatus.notDetermined,
      statusError: StateError('unknown push authorization status: null'),
    );

    expect(await h.gate.resolve(), PushGateDecision.skip);
  });

  test('a registration failure while authorized still skips', () async {
    final h = Harness(
      status: PushAuthorizationStatus.authorized,
      registerStatusCode: 401,
    );

    // Never throws out of resolve(): push must not break sign-in.
    expect(await h.gate.resolve(), PushGateDecision.skip);
  });

  test("deferPriming() records the clock's now", () async {
    final h = Harness(status: PushAuthorizationStatus.notDetermined);

    await h.gate.deferPriming();

    expect(h.prefs.deferredAt, now);
    expect(h.prefs.writeCount, 1);
  });

  test(
    '"Not now" then a fresh launch skips — the nag this card fixes',
    () async {
      final h = Harness(status: PushAuthorizationStatus.notDetermined);
      expect(await h.gate.resolve(), PushGateDecision.prime);

      await h.gate.deferPriming();

      expect(await h.gate.resolve(), PushGateDecision.skip);
    },
  );
}
