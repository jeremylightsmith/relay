import 'package:flutter/foundation.dart';

/// Environment-aware configuration for the Relay mobile wrapper.
///
/// The base URL is chosen automatically:
///   * Debug builds  -> http://localhost:4000 (local Phoenix server)
///   * Release/profile builds -> https://relayboard.fly.dev (production)
///
/// Override at build/run time with:
///   flutter run --dart-define=APP_API_URL=http://192.168.1.5:4000
class AppConfig {
  const AppConfig._();

  /// Compile-time override, e.g. `--dart-define=APP_API_URL=...`.
  static const String _override = String.fromEnvironment(
    'APP_API_URL',
    defaultValue: '',
  );

  /// Production Phoenix host (Fly app `relayboard`).
  static const String productionUrl = 'https://relayboard.fly.dev';

  /// Localhost for the iOS simulator (Android emulator uses 10.0.2.2).
  static const String localhostUrl = 'http://localhost:4000';

  static String get apiBaseUrl {
    if (_override.isNotEmpty) return _override;
    return kDebugMode ? localhostUrl : productionUrl;
  }

  static bool get isDebugMode => kDebugMode;

  static String get environmentName {
    if (_override.isNotEmpty) return 'override';
    return kDebugMode ? 'development' : 'production';
  }
}
