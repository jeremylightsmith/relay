import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/config.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/http_providers.dart';
import 'package:relay_mobile/features/auth/session_store.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';

import 'support/fake_push_platform.dart';
import 'support/stub_adapter.dart';

const _user = {'id': 1, 'name': 'Dana', 'email': 'dana@acme.co'};

ProviderContainer containerWith({
  required SessionStore store,
  required StubAdapter adapter,
  BoardPrefs? boardPrefs,
}) {
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(store),
      boardPrefsProvider.overrideWithValue(boardPrefs ?? InMemoryBoardPrefs()),
      pushPlatformProvider.overrideWithValue(FakePushPlatform()),
      // The real dio, minus the socket: same jar + interceptor, stubbed adapter.
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

/// Reading authProvider kicks off _restore(); let it land.
Future<AuthState> restore(ProviderContainer container) async {
  container.read(authProvider);
  await pumpEventQueue();
  return container.read(authProvider);
}

void main() {
  // signOut() touches GoogleSignIn's platform channel (swallowed) — it still
  // needs a binding to swallow against.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a stored cookie that /me accepts restores a signed-in session',
    () async {
      final store = InMemorySessionStore('cookie-value');
      final adapter = StubAdapter(body: {'success': true, 'user': _user});
      final container = containerWith(store: store, adapter: adapter);

      final state = await restore(container);

      expect(state.status, AuthStatus.signedIn);
      expect(state.email, 'dana@acme.co');
      expect(adapter.requests.single.path, '/api/auth/native/me');

      // The restored cookie was seeded, so it rides the next request too.
      final cookies = await container
          .read(cookieJarProvider)
          .loadForRequest(Uri.parse(AppConfig.baseUrl));
      expect(cookies.map((c) => c.name), contains('_relay_key'));
    },
  );

  test('a cookie refreshed by /me is persisted for the next launch', () async {
    final store = InMemorySessionStore('old-cookie');
    final adapter = StubAdapter(
      body: {'success': true, 'user': _user},
      headers: {
        'set-cookie': ['_relay_key=refreshed-cookie; Path=/; Max-Age=604800'],
      },
    );
    final container = containerWith(store: store, adapter: adapter);

    final state = await restore(container);

    expect(state.status, AuthStatus.signedIn);
    expect(
      store.value,
      'refreshed-cookie',
      reason:
          'the server slid the 7-day window (RLY-127); dropping the refreshed '
          'cookie would let the Keychain copy age out anyway',
    );
  });

  test('a stored cookie that /me rejects is cleared, and signs out', () async {
    final store = InMemorySessionStore('stale-cookie');
    final adapter = StubAdapter(
      statusCode: 401,
      body: {'success': false, 'error': 'Not signed in'},
    );
    final container = containerWith(store: store, adapter: adapter);

    final state = await restore(container);

    expect(state.status, AuthStatus.signedOut);
    expect(
      store.value,
      isNull,
      reason: 'a credential the server rejected must not survive the launch',
    );
  });

  test(
    'a network error signs out but KEEPS the cookie for the next launch',
    () async {
      final store = InMemorySessionStore('good-cookie');
      final adapter = StubAdapter(failure: const SocketException('offline'));
      final container = containerWith(store: store, adapter: adapter);

      final state = await restore(container);

      expect(state.status, AuthStatus.signedOut);
      expect(
        store.value,
        'good-cookie',
        reason: 'a flaky network must not sign the user out for good',
      );
    },
  );

  test('an empty store signs out without calling /me', () async {
    final store = InMemorySessionStore();
    final adapter = StubAdapter();
    final container = containerWith(store: store, adapter: adapter);

    final state = await restore(container);

    expect(state.status, AuthStatus.signedOut);
    expect(
      adapter.requests,
      isEmpty,
      reason: 'nothing to verify — no round-trip',
    );
  });

  test('persistSession stores the jar session cookie', () async {
    final store = InMemorySessionStore();
    final container = containerWith(store: store, adapter: StubAdapter());
    await restore(container);

    final uri = Uri.parse(AppConfig.baseUrl);
    await container.read(cookieJarProvider).saveFromResponse(uri, [
      Cookie('_relay_key', 'fresh-from-sign-in')
        ..domain = uri.host
        ..path = '/',
    ]);

    await container.read(authProvider.notifier).persistSession();

    expect(store.value, 'fresh-from-sign-in');
  });

  test('signing out clears the persisted cookie', () async {
    final store = InMemorySessionStore('cookie-value');
    final adapter = StubAdapter(body: {'success': true, 'user': _user});
    final container = containerWith(store: store, adapter: adapter);
    await restore(container);

    await container.read(authProvider.notifier).signOut();

    expect(store.value, isNull);
    expect(container.read(authProvider).status, AuthStatus.signedOut);
  });

  test('signing out forgets the last-viewed board (RLY-95)', () async {
    final store = InMemorySessionStore('cookie-value');
    final boardPrefs = InMemoryBoardPrefs('marketing-site');
    final adapter = StubAdapter(body: {'success': true, 'user': _user});
    final container = containerWith(
      store: store,
      adapter: adapter,
      boardPrefs: boardPrefs,
    );
    await restore(container);

    await container.read(authProvider.notifier).signOut();

    expect(boardPrefs.slug, isNull);
    expect(container.read(authProvider).status, AuthStatus.signedOut);
  });
}
