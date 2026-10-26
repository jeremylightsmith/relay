import 'package:flutter/foundation.dart';

/// Environment-aware configuration for the Hamaca mobile wrapper.
///
/// Note: the shipped app does not read this class. Its host is
/// `AppConfig.baseUrl` in `lib/config.dart`, baked in from the
/// `RELAY_BASE_URL` dart-define (`https://hamaca.app` for release builds; see
/// `ios/fastlane/Fastfile`). Keep [productionUrl] in step with it.
///
/// The base URL is chosen automatically:
///   * Debug builds  -> http://localhost:4000 (local Phoenix server)
///   * Release/profile builds -> https://hamaca.app (production)
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

  /// Production Phoenix host (`https://hamaca.app`, served by Fly app `relayboard`).
  static const String productionUrl = 'https://hamaca.app';

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
