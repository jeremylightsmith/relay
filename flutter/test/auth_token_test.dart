// The bearer token seam (RLY-78 / D5): `/api/all/*` is bearer-only, so a signed-in
// app with no token renders MissingTokenException instead of the inbox. Both ways a
// session becomes live must therefore carry a token out — an interactive sign-in
// and, because RLY-86 persists only the cookie, a restore.
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/config.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/http_providers.dart';
import 'package:relay_mobile/features/auth/session_store.dart';
import 'package:relay_mobile/features/push/push_service.dart';

import 'support/fake_push_platform.dart';
import 'support/stub_adapter.dart';

const _user = {'id': 1, 'name': 'Dana', 'email': 'dana@acme.co'};

ProviderContainer containerWith(StubAdapter adapter, {String? persisted}) {
  final container = ProviderContainer(
    overrides: [
      sessionStoreProvider.overrideWithValue(InMemorySessionStore(persisted)),
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
  // The auth flow touches platform channels (swallowed) — it still needs a
  // binding to swallow against.
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a restored session carries the bearer token out of the verify',
    () async {
      final adapter = StubAdapter(
        body: {'success': true, 'user': _user, 'token': 'relayu_abc_def'},
      );
      final container = containerWith(adapter, persisted: 'cookie-value');

      final state = await restore(container);

      expect(state.signedIn, isTrue);
      // The token has to reach the seam ApiClient reads, or the inbox shows
      // MissingTokenException despite a perfectly good session.
      expect(container.read(authTokenProvider), 'relayu_abc_def');
    },
  );

  test('a tokenless verify response leaves the seam null', () async {
    final adapter = StubAdapter(body: {'success': true, 'user': _user});
    final container = containerWith(adapter, persisted: 'cookie-value');

    final state = await restore(container);

    // Signed in, but honestly tokenless — the inbox says why rather than
    // rendering an empty, "you're all caught up" queue.
    expect(state.signedIn, isTrue);
    expect(container.read(authTokenProvider), isNull);
  });
}
