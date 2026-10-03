import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/config.dart';
import 'package:relay_mobile/features/auth/apple_credential.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/http_providers.dart';
import 'package:relay_mobile/features/auth/session_store.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'support/fake_push_platform.dart';
import 'support/stub_adapter.dart';

const _credential = AuthorizationCredentialAppleID(
  userIdentifier: 'u1',
  identityToken: 'apple-jwt',
  givenName: 'Alice',
  familyName: 'Apple',
  email: null,
  authorizationCode: 'c',
  state: null,
);

const _generic = 'Something went wrong signing you in. Please try again.';

/// Records the hashed nonce Apple was asked to embed, then answers with
/// [result] (or throws [error]).
class FakeAppleRequest {
  FakeAppleRequest({this.result = _credential, this.error, this.gate});

  final AuthorizationCredentialAppleID result;
  final Object? error;
  final Completer<void>? gate;
  String? hashedNonce;

  Future<AuthorizationCredentialAppleID> call(String hashedNonce) async {
    this.hashedNonce = hashedNonce;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return result;
  }
}

ProviderContainer containerWith({
  required SessionStore store,
  required StubAdapter adapter,
  required FakeAppleRequest apple,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(store),
      boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs()),
      pushPlatformProvider.overrideWithValue(FakePushPlatform()),
      appleCredentialRequestProvider.overrideWithValue(apple.call),
      dioProvider.overrideWith(
        (ref) =>
            Dio(
                BaseOptions(
                  baseUrl: AppConfig.baseUrl,
                  validateStatus: (s) => s != null && s < 500,
                ),
              )
              ..interceptors.add(CookieManager(ref.watch(cookieJarProvider)))
              ..httpClientAdapter = adapter,
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Land the (empty-store) restore first, so it can't race the sign-in.
Future<AuthController> ready(ProviderContainer container) async {
  container.read(authProvider);
  await pumpEventQueue();
  return container.read(authProvider.notifier);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a successful Apple sign-in exchanges the token with the raw nonce '
      'and persists the session', () async {
    final store = InMemorySessionStore();
    final apple = FakeAppleRequest();
    final adapter = StubAdapter(
      body: {
        'success': true,
        'user': {'id': 1, 'name': 'Alice Apple', 'email': 'alice@example.com'},
        'token': 'relayu_x',
      },
      headers: {
        'set-cookie': ['_relay_key=apple-cookie; Path=/'],
      },
    );
    final container = containerWith(
      store: store,
      adapter: adapter,
      apple: apple,
    );

    await (await ready(container)).signInWithApple();

    final request = adapter.requests.single;
    expect(request.path, '/api/auth/native/apple');
    final body = request.data as Map;
    expect(body['identity_token'], 'apple-jwt');
    expect(body['given_name'], 'Alice');
    expect(body['family_name'], 'Apple');
    expect(apple.hashedNonce, isNotNull);
    expect(sha256Hex(body['nonce'] as String), apple.hashedNonce);

    final state = container.read(authProvider);
    expect(state.status, AuthStatus.signedIn);
    expect(state.email, 'alice@example.com');
    expect(state.token, 'relayu_x');
    expect(store.value, 'apple-cookie');
  });

  test('a cancelled Apple sheet signs out silently, with no request', () async {
    final adapter = StubAdapter();
    final container = containerWith(
      store: InMemorySessionStore(),
      adapter: adapter,
      apple: FakeAppleRequest(
        error: const SignInWithAppleAuthorizationException(
          code: AuthorizationErrorCode.canceled,
          message: '',
        ),
      ),
    );

    await (await ready(container)).signInWithApple();

    final state = container.read(authProvider);
    expect(state.status, AuthStatus.signedOut);
    expect(state.error, isNull);
    expect(adapter.requests, isEmpty);
  });

  test('a backend rejection names the Apple ID and stores nothing', () async {
    final store = InMemorySessionStore();
    final container = containerWith(
      store: store,
      adapter: StubAdapter(
        statusCode: 401,
        body: {'success': false, 'error': 'Invalid token'},
      ),
      apple: FakeAppleRequest(),
    );

    await (await ready(container)).signInWithApple();

    final state = container.read(authProvider);
    expect(state.status, AuthStatus.signedOut);
    expect(state.error, "Relay couldn't sign you in with that Apple ID.");
    expect(state.method, SignInMethod.apple);
    expect(store.value, isNull);
  });

  test(
    'a credential with no identity token fails generically, no request',
    () async {
      final adapter = StubAdapter();
      final container = containerWith(
        store: InMemorySessionStore(),
        adapter: adapter,
        apple: FakeAppleRequest(
          result: const AuthorizationCredentialAppleID(
            userIdentifier: 'u1',
            identityToken: null,
            givenName: null,
            familyName: null,
            email: null,
            authorizationCode: 'c',
            state: null,
          ),
        ),
      );

      await (await ready(container)).signInWithApple();

      final state = container.read(authProvider);
      expect(adapter.requests, isEmpty);
      expect(state.status, AuthStatus.signedOut);
      expect(state.error, _generic);
    },
  );

  test('while Apple is in flight the state is signingIn via Apple', () async {
    final gate = Completer<void>();
    final container = containerWith(
      store: InMemorySessionStore(),
      adapter: StubAdapter(statusCode: 401, body: {'success': false}),
      apple: FakeAppleRequest(gate: gate),
    );

    final pending = (await ready(container)).signInWithApple();
    await pumpEventQueue();

    final state = container.read(authProvider);
    expect(state.status, AuthStatus.signingIn);
    expect(state.method, SignInMethod.apple);

    gate.complete();
    await pending;
  });

  test('raw nonces are random and long; sha256Hex is lowercase hex', () {
    final a = generateRawNonce();
    final b = generateRawNonce();
    expect(a, isNot(b));
    expect(a.length, greaterThanOrEqualTo(32));
    expect(b.length, greaterThanOrEqualTo(32));

    final digest = sha256Hex('raw-nonce-1');
    expect(digest, matches(RegExp(r'^[0-9a-f]{64}$')));
    // Pinned: `printf 'raw-nonce-1' | shasum -a 256` — what the server recomputes.
    expect(
      digest,
      'bef53b3c45cc1de4b7ef424e18831896dc04065c79b42250431fa69cd123e1e3',
    );
  });
}
