import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What *we* remember about asking for push — deliberately separate from
/// PushPlatform's "what iOS thinks about notifications". Different concerns with
/// different lifetimes (RLY-84 §3).
abstract class PushPrefs {
  /// When the user last tapped "Not now" on AUTH-03, or null if they never have.
  Future<DateTime?> primingDeferredAt();

  /// Remember a "Not now" so we don't re-prime on the next launch.
  Future<void> setPrimingDeferredAt(DateTime when);
}

/// Backed by iOS `UserDefaults`, over the `relay/push` channel we already own.
///
/// Deliberately not `shared_preferences`: that is a new dependency for a single
/// scalar and AGENTS.md's no-new-deps rule bites. This is also *more* testable
/// from Dart (a fake PushPrefs, no plugin bindings). If a second preference ever
/// appears, adopt shared_preferences then and swap this one implementation.
class IosPushPrefs implements PushPrefs {
  /// The same channel IosPushPlatform uses — **invoke-only**. Never call
  /// setMethodCallHandler here: a channel has exactly one handler, and
  /// IosPushPlatform's owns notification-tap delivery. A second one would
  /// silently steal taps.
  static const MethodChannel _channel = MethodChannel('relay/push');

  @override
  Future<DateTime?> primingDeferredAt() async {
    final epochMs = await _channel.invokeMethod<int>('primingDeferredAt');
    return epochMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  }

  @override
  Future<void> setPrimingDeferredAt(DateTime when) async {
    await _channel.invokeMethod<void>('setPrimingDeferredAt', {
      'epochMs': when.toUtc().millisecondsSinceEpoch,
    });
  }
}

final pushPrefsProvider = Provider<PushPrefs>((ref) => IosPushPrefs());
