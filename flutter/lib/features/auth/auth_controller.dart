// F2 auth: native Google sign-in → backend token exchange → Phoenix session.
//
// Flow: google_sign_in (v7) yields a Google ID token → POST it to the backend's
// `/api/auth/native/google` (RelayWeb.NativeAuthController) → the response carries
// `Set-Cookie: _relay_key=…`, which dio's cookie jar captures. We then inject that
// cookie into flutter_inappwebview's store so embedded LiveView renders signed-in.
//
// RLY-86: that cookie is also persisted to the Keychain and, on launch, restored
// and verified against `/api/auth/native/me` — so a cold-start push tap lands on
// the card instead of the sign-in screen.
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../config.dart';
import '../push/push_service.dart';
import 'auth_errors.dart';
import 'http_providers.dart';
import 'session_store.dart';

/// Phoenix's session cookie (see RelayWeb.Endpoint's `@session_options`).
const relaySessionCookie = '_relay_key';

/// Where auth is in its lifecycle.
///
/// [restoring] is the one that earns its keep: with `signedIn => user != null`,
/// "not yet restored" was indistinguishable from "signed out", so a cold-start
/// deep link bounced to Welcome before the Keychain read even returned (RLY-86 §4).
enum AuthStatus { restoring, signedOut, signingIn, signedIn }

class AuthState {
  const AuthState({this.status = AuthStatus.restoring, this.user, this.error});

  final AuthStatus status;
  final Map<String, dynamic>? user;
  final String? error;

  bool get signedIn => status == AuthStatus.signedIn;
  bool get signingIn => status == AuthStatus.signingIn;
  bool get restoring => status == AuthStatus.restoring;
  String get email => (user?['email'] ?? '') as String;
}

class AuthController extends Notifier<AuthState> {
  final GoogleSignIn _google = GoogleSignIn.instance;
  bool _googleInitialized = false;

  @override
  AuthState build() {
    // Notifier.build() is synchronous, so hand back `restoring` and let _restore()
    // land the real state. The router holds any deep link on /splash until it does.
    _restore();
    return const AuthState();
  }

  CookieJar get _jar => ref.read(cookieJarProvider);
  Dio get _dio => ref.read(dioProvider);
  SessionStore get _store => ref.read(sessionStoreProvider);

  /// Launch: restore the persisted cookie, then verify it before claiming to be
  /// signed in (RLY-86 §5). The verify round-trip is what turns a stale credential
  /// into a clean sign-out instead of a mysterious 401 deep inside a webview.
  Future<void> _restore() async {
    final stored = await _store.read();
    if (stored == null) {
      // Nothing to verify — no round-trip.
      state = const AuthState(status: AuthStatus.signedOut);
      return;
    }

    final cookie = _sessionCookie(stored);
    await _jar.saveFromResponse(Uri.parse(AppConfig.baseUrl), [cookie]);
    await _injectSessionIntoWebviews([cookie]);

    try {
      final resp = await _dio.get('/api/auth/native/me');
      final ok =
          resp.statusCode == 200 &&
          (resp.data is Map) &&
          resp.data['success'] == true;

      if (ok) {
        state = AuthState(
          status: AuthStatus.signedIn,
          user: Map<String, dynamic>.from(resp.data['user'] as Map),
        );
        return;
      }

      // A real answer, and it says no: the credential is dead. Drop it.
      await _clearSession();
      state = const AuthState(status: AuthStatus.signedOut);
    } catch (e) {
      // We couldn't ask. Keep the cookie — a flaky network must not sign the user
      // out for good; the next launch retries.
      debugPrint('[auth] session verify failed: $e');
      state = const AuthState(status: AuthStatus.signedOut);
    }
  }

  Future<void> signInWithGoogle() async {
    state = const AuthState(status: AuthStatus.signingIn);
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
        state = const AuthState(status: AuthStatus.signedOut); // cancelled
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
        throw SignInRejected(resp.statusCode);
      }

      final cookies = await _jar.loadForRequest(Uri.parse(AppConfig.baseUrl));
      await _injectSessionIntoWebviews(cookies);
      await persistSession();
      state = AuthState(
        status: AuthStatus.signedIn,
        user: Map<String, dynamic>.from(resp.data['user'] as Map),
      );
    } catch (e) {
      // The raw error stays debuggable here and never reaches the UI.
      debugPrint('Sign-in failed: $e');
      final message = signInErrorMessage(e);
      state = AuthState(status: AuthStatus.signedOut, error: message);
    }
  }

  /// Persist whatever session cookie the jar currently holds, so the next cold
  /// start can restore it. Public so it can be exercised without driving Google.
  @visibleForTesting
  Future<void> persistSession() async {
    final cookies = await _jar.loadForRequest(Uri.parse(AppConfig.baseUrl));
    for (final c in cookies) {
      if (c.name == relaySessionCookie) {
        await _store.write(c.value);
        return;
      }
    }
  }

  Cookie _sessionCookie(String value) {
    final uri = Uri.parse(AppConfig.baseUrl);
    return Cookie(relaySessionCookie, value)
      ..domain = uri.host
      ..path = '/'
      ..httpOnly = true
      ..secure = uri.scheme == 'https';
  }

  /// Copy [cookies] into the webview cookie store, so an embedded LiveView (board,
  /// spec, comments) loads authenticated.
  ///
  /// Takes the cookies rather than re-reading the jar, because a restore has the
  /// cookie in hand before the jar is the source of truth. Best-effort, like push:
  /// the webview store is a cache of the session, not the session itself, and
  /// `flutter test` has no webview platform at all.
  Future<void> _injectSessionIntoWebviews(List<Cookie> cookies) async {
    final uri = Uri.parse(AppConfig.baseUrl);
    try {
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
    } catch (e) {
      debugPrint('[auth] webview cookie injection failed: $e');
    }
  }

  /// Forget the session everywhere it is held: dio's jar, the webview store, and
  /// the Keychain.
  Future<void> _clearSession() async {
    await _jar.deleteAll();
    await _store.clear();
    try {
      await iaw.CookieManager.instance().deleteAllCookies();
    } catch (e) {
      debugPrint('[auth] webview cookie clear failed: $e');
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
    await _clearSession();
    state = const AuthState(status: AuthStatus.signedOut);
  }
}

final authProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
