// F2 auth: native Google sign-in → backend token exchange → Phoenix session.
//
// Flow: google_sign_in (v7) yields a Google ID token → POST it to the backend's
// `/api/auth/native/google` (RelayWeb.NativeAuthController) → the response carries
// `Set-Cookie: _relay_key=…`, which dio's cookie jar captures. We then inject that
// cookie into flutter_inappwebview's store so embedded LiveView renders signed-in.
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../config.dart';
import '../push/push_service.dart';
import 'http_providers.dart';

class AuthState {
  const AuthState({this.user, this.signingIn = false, this.error});
  final Map<String, dynamic>? user;
  final bool signingIn;
  final String? error;

  bool get signedIn => user != null;
  String get email => (user?['email'] ?? '') as String;
}

class AuthController extends Notifier<AuthState> {
  final GoogleSignIn _google = GoogleSignIn.instance;
  bool _googleInitialized = false;

  @override
  AuthState build() {
    return const AuthState();
  }

  CookieJar get _jar => ref.read(cookieJarProvider);
  Dio get _dio => ref.read(dioProvider);

  Future<void> signInWithGoogle() async {
    state = const AuthState(signingIn: true);
    try {
      if (!_googleInitialized) {
        await _google.initialize(
          clientId: AppConfig.googleIosClientId,
          serverClientId: AppConfig.googleServerClientId,
        );
        _googleInitialized = true;
      }

      // v7: authenticate() triggers the flow; the signed-in user arrives on the
      // authenticationEvents stream.
      final eventFuture = _google.authenticationEvents.first;
      await _google.authenticate();
      final event = await eventFuture;
      if (event is! GoogleSignInAuthenticationEventSignIn) {
        state = const AuthState(); // cancelled
        return;
      }

      final idToken = event.user.authentication.idToken;
      if (idToken == null) {
        throw Exception('Google returned no ID token');
      }

      final resp = await _dio.post(
        '/api/auth/native/google',
        data: {'id_token': idToken},
      );
      final ok =
          resp.statusCode == 200 &&
          (resp.data is Map) &&
          resp.data['success'] == true;
      if (!ok) {
        throw Exception(
          'Backend rejected sign-in: ${resp.statusCode} ${resp.data}',
        );
      }

      await _injectSessionIntoWebviews();
      state = AuthState(
        user: Map<String, dynamic>.from(resp.data['user'] as Map),
      );
    } catch (e) {
      state = AuthState(error: e.toString());
    }
  }

  /// Copy the session cookie dio captured into the webview cookie store, so an
  /// embedded LiveView (board, spec, comments) loads authenticated.
  Future<void> _injectSessionIntoWebviews() async {
    final uri = Uri.parse(AppConfig.baseUrl);
    final cookies = await _jar.loadForRequest(uri);
    final cm = iaw.CookieManager.instance();
    for (final c in cookies) {
      await cm.setCookie(
        url: iaw.WebUri(AppConfig.baseUrl),
        name: c.name,
        value: c.value,
        domain: uri.host,
        path: '/',
        isSecure: uri.scheme == 'https',
        isHttpOnly: true,
      );
    }
  }

  Future<void> signOut() async {
    // Unregister *before* clearing the jar — once the session cookie is gone the
    // DELETE would 401 and the device would keep receiving pushes (RLY-81 §11).
    final push = ref.read(pushServiceProvider);
    final token = push.token;
    if (token != null) await push.disable(token);

    try {
      await _google.signOut();
    } catch (_) {}
    await _jar.deleteAll();
    await iaw.CookieManager.instance().deleteAllCookies();
    state = const AuthState();
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
