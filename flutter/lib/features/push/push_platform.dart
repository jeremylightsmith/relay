import 'package:flutter/services.dart';

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
}
