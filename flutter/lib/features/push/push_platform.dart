import 'package:flutter/services.dart';

/// What iOS currently thinks about this app's notification permission. Mirrors
/// UNAuthorizationStatus (RLY-84 §1).
enum PushAuthorizationStatus {
  /// The one-shot OS prompt is unspent — AUTH-03 is what stops us burning it cold.
  notDetermined,

  /// iOS will not show the prompt again.
  denied,
  authorized,
  provisional,
  ephemeral,
}

/// The native push seam. iOS-only by design — Android/FCM is deferred (RLY-103),
/// and we deliberately avoid firebase_messaging: it is FCM-centric weight we do
/// not need for one APNs registration.
///
/// An interface rather than a bare MethodChannel so PushService is testable
/// without the OS (see test/push_service_test.dart).
abstract class PushPlatform {
  /// Shows the iOS permission dialog and, if granted, registers for remote
  /// notifications and resolves the APNs device token. Null when the user
  /// declines or registration fails.
  Future<String?> requestPermissionAndToken();

  /// The notification payload the app was cold-started from, if any.
  Future<Map<String, dynamic>?> initialNotification();

  /// Called with the payload whenever a notification is tapped while the app is
  /// already running (foreground or background).
  void onNotificationTap(void Function(Map<String, dynamic> payload) handler);

  /// What iOS currently thinks about notification permission. **Throws** when the
  /// status cannot be read (channel error, non-iOS); callers treat that as
  /// "unavailable" and skip (RLY-84 §1).
  Future<PushAuthorizationStatus> authorizationStatus();

  /// Registers for remote notifications **without** requesting authorization — no
  /// prompt, no dialog — and resolves the APNs device token. Null when the app is
  /// not authorized or registration fails.
  ///
  /// This is the silent re-registration path (RLY-84 §2): once the gate stops
  /// showing AUTH-03, this is the only thing keeping an authorized device
  /// registered.
  Future<String?> tokenIfAuthorized();
}

/// The real implementation, over the `relay/push` channel implemented in
/// ios/Runner/AppDelegate.swift.
class IosPushPlatform implements PushPlatform {
  IosPushPlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTap' && _handler != null) {
        _handler!(Map<String, dynamic>.from(call.arguments as Map));
      }
    });
  }

  static const MethodChannel _channel = MethodChannel('relay/push');
  void Function(Map<String, dynamic>)? _handler;

  @override
  Future<String?> requestPermissionAndToken() async {
    return _channel.invokeMethod<String>('requestPermissionAndToken');
  }

  @override
  Future<Map<String, dynamic>?> initialNotification() async {
    final payload = await _channel.invokeMethod<Map<Object?, Object?>>(
      'initialNotification',
    );
    return payload == null ? null : Map<String, dynamic>.from(payload);
  }

  @override
  void onNotificationTap(void Function(Map<String, dynamic> payload) handler) {
    _handler = handler;
  }

  @override
  Future<PushAuthorizationStatus> authorizationStatus() async {
    final name = await _channel.invokeMethod<String>('authorizationStatus');
    return _statusFromName(name);
  }

  @override
  Future<String?> tokenIfAuthorized() {
    return _channel.invokeMethod<String>('tokenIfAuthorized');
  }

  /// Null (an `@unknown` UNAuthorizationStatus) or an unrecognised name means the
  /// status is unavailable. Throw rather than guess: every gate decision hangs off
  /// this value, and PushOnboarding already turns a throw into a safe skip.
  PushAuthorizationStatus _statusFromName(String? name) {
    switch (name) {
      case 'notDetermined':
        return PushAuthorizationStatus.notDetermined;
      case 'denied':
        return PushAuthorizationStatus.denied;
      case 'authorized':
        return PushAuthorizationStatus.authorized;
      case 'provisional':
        return PushAuthorizationStatus.provisional;
      case 'ephemeral':
        return PushAuthorizationStatus.ephemeral;
      default:
        throw StateError('unknown push authorization status: $name');
    }
  }
}
