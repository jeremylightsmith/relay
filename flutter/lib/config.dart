/// App configuration, supplied at build time via --dart-define. None of these
/// are secrets: the iOS OAuth client id and the Relay host are public app
/// config (an iOS OAuth client has no client secret), so they're safe to bake in.
class AppConfig {
  /// The Relay server. Dev default is the local Phoenix server on :4003.
  static const String baseUrl =
      String.fromEnvironment('RELAY_BASE_URL', defaultValue: 'http://localhost:4003');

  /// The iOS OAuth client id (…apps.googleusercontent.com). Its reversed form is
  /// the CFBundleURLScheme in Info.plist so Google can redirect back to the app.
  static const String googleIosClientId =
      String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

  /// The *web* OAuth client id, passed as google_sign_in's serverClientId so the
  /// returned ID token's audience matches the backend's GoogleTokenValidator.
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
}
