// The named `platform`/`dio` constructor params below shadow their private
// field names (`_platform`/`_dio`), so they can't be initializing formals
// (`this._platform`) without making the params private too, which callers
// outside this library couldn't pass.
// ignore_for_file: prefer_initializing_formals
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/http_providers.dart';
import 'push_platform.dart';

/// Owns the device-token lifecycle: OS permission → APNs token → register with
/// the backend; and on sign-out, unregister.
///
/// A plain injectable class (not a Notifier) so tests construct it directly with
/// a fake platform and a dio adapter — the repo's structural-seam convention.
class PushService {
  PushService({required PushPlatform platform, required Dio dio})
    : _platform = platform,
      _dio = dio;

  final PushPlatform _platform;
  final Dio _dio;
  String? _token;

  /// The registered APNs device token, or null when push is not enabled.
  String? get token => _token;

  /// Asks iOS for permission and, if granted, registers the resulting device
  /// token with the backend. Returns whether push is now enabled. Never throws:
  /// push is best-effort and must not break sign-in.
  Future<bool> enable() async {
    try {
      final token = await _platform.requestPermissionAndToken();
      if (token == null) return false;

      final resp = await _dio.post(
        '/api/all/devices',
        data: {'token': token, 'platform': 'ios'},
      );

      final ok = resp.statusCode == 201 || resp.statusCode == 200;
      if (ok) _token = token;
      return ok;
    } catch (e) {
      debugPrint('[push] enable failed: $e');
      return false;
    }
  }

  /// Unregisters [token] on sign-out. Never throws — the backend delete is
  /// idempotent and a failure must not block signing out.
  Future<void> disable(String token) async {
    try {
      await _dio.delete('/api/all/devices/$token');
    } catch (e) {
      debugPrint('[push] disable failed: $e');
    } finally {
      _token = null;
    }
  }
}

/// The one PushPlatform instance. Must be a singleton: IosPushPlatform's
/// constructor installs the `relay/push` MethodCallHandler, and a channel has
/// exactly one — a second instance would silently steal tap delivery from the
/// first.
final pushPlatformProvider = Provider<PushPlatform>((ref) => IosPushPlatform());

/// The app's PushService, on the shared iOS channel and the session-carrying dio.
final pushServiceProvider = Provider<PushService>((ref) {
  return PushService(
    platform: ref.watch(pushPlatformProvider),
    dio: ref.watch(dioProvider),
  );
});
