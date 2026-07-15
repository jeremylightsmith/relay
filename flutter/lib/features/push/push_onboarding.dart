// The named constructor params below shadow their private field names
// (`_platform`/`_service`/`_prefs`/`_clock`), so they can't be initializing
// formals (`this._platform`) without making the params private too, which
// callers outside this library couldn't pass. Same situation as PushService.
// ignore_for_file: prefer_initializing_formals
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'push_platform.dart';
import 'push_prefs.dart';
import 'push_service.dart';

/// Whether AUTH-03 should be shown this launch.
enum PushGateDecision {
  /// Route to /push-permission.
  prime,

  /// Do nothing. **Not** `router.go('/needs-you')` — routerProvider's auth
  /// redirect already landed this sign-in there; the gate only adds a detour.
  skip,
}

/// The whole "should we show AUTH-03?" decision in one place (RLY-84 §1), plus its
/// inseparable other half: silently re-registering the device token when push is
/// already authorized (§2).
///
/// A plain injectable class rather than a Notifier, matching the repo's
/// structural-seam convention (buildRouter, PushService): tests construct it with
/// fakes and an injected clock — no mocking package, no OS.
class PushOnboarding {
  PushOnboarding({
    required PushPlatform platform,
    required PushService service,
    required PushPrefs prefs,
    DateTime Function() clock = DateTime.now,
  }) : _platform = platform,
       _service = service,
       _prefs = prefs,
       _clock = clock;

  final PushPlatform _platform;
  final PushService _service;
  final PushPrefs _prefs;
  final DateTime Function() _clock;

  /// How long a "Not now" suppresses AUTH-03 before we prime once more.
  ///
  /// Deliberately not once-ever: "Not now" never invokes the OS prompt, so iOS
  /// stays notDetermined — and an app that has never requested authorization does
  /// not appear under Settings → Notifications at all. Once-ever would make a
  /// single mis-tap an unrecoverable dead end on a card whose whole value is push.
  /// For strictly-once-ever, set this to Duration(days: 36500); nothing else
  /// changes.
  static const Duration primingCooldown = Duration(days: 7);

  /// Decides whether AUTH-03 should be shown this launch, and silently
  /// re-registers the device token when push is already authorized.
  ///
  /// Never throws — push is best-effort and must not break sign-in. Any failure
  /// falls back to [PushGateDecision.skip]: never show a screen whose button we
  /// cannot back up.
  Future<PushGateDecision> resolve() async {
    try {
      final status = await _platform.authorizationStatus();

      switch (status) {
        case PushAuthorizationStatus.authorized:
        case PushAuthorizationStatus.provisional:
        case PushAuthorizationStatus.ephemeral:
          // §2: the other half of the skip. RLY-81 registers the token only on the
          // "Allow" tap, so the moment we stop showing AUTH-03 this is the only
          // thing keeping the device registered. Idempotent (the backend upserts
          // by token), and Apple's guidance is to re-register on every launch
          // anyway because the token can change.
          await _service.registerIfAuthorized();
          return PushGateDecision.skip;

        case PushAuthorizationStatus.denied:
          // iOS will not show the prompt again; AUTH-03 could only lie about what
          // its button does.
          return PushGateDecision.skip;

        case PushAuthorizationStatus.notDetermined:
          // `await` matters: without it the future escapes the try/catch.
          return await _primeUnlessRecentlyDeferred();
      }
    } catch (e) {
      debugPrint('[push] gate unavailable, skipping AUTH-03: $e');
      return PushGateDecision.skip;
    }
  }

  /// "Not now" — remember the deferral so we don't nag on the next launch.
  Future<void> deferPriming() async {
    try {
      await _prefs.setPrimingDeferredAt(_clock());
    } catch (e) {
      debugPrint('[push] could not record the priming deferral: $e');
    }
  }

  Future<PushGateDecision> _primeUnlessRecentlyDeferred() async {
    final deferredAt = await _prefs.primingDeferredAt();
    if (deferredAt == null) return PushGateDecision.prime;

    final elapsed = _clock().difference(deferredAt);
    return elapsed < primingCooldown
        ? PushGateDecision.skip
        : PushGateDecision.prime;
  }
}

/// The gate, on the shared platform / service / prefs singletons.
final pushOnboardingProvider = Provider<PushOnboarding>((ref) {
  return PushOnboarding(
    platform: ref.watch(pushPlatformProvider),
    service: ref.watch(pushServiceProvider),
    prefs: ref.watch(pushPrefsProvider),
  );
});
