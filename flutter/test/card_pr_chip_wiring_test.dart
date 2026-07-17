import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/card/pr_launcher.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import 'review_queue_test.dart' show FakeDecisionApi, FakeFeedRepository;
import 'support/fake_auth.dart';
import 'support/stub_adapter.dart';

ApiClient clientWith(StubAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  final client = ApiClient(tokenReader: () => 'relayu_t', dio: dio);
  client.dio.httpClientAdapter = adapter;
  return client;
}

Map<String, dynamic> summary(String? prUrl) => {
  'data': {'ref': 'RLY-A', 'pr_url': prUrl},
};

/// Pumps CardScreen the way the app reaches it (via the /cards/:ref route). No queue
/// pre-seed: an in_review CardScreen seeds itself (see _seedIfNeeded), and needs_input
/// renders no bar at all.
Future<void> pumpCard(
  WidgetTester tester, {
  required StubAdapter adapter,
  PrLauncher? launcher,
  String kind = 'in_review',
}) async {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(clientWith(adapter)),
      decisionApiProvider.overrideWithValue(FakeDecisionApi()),
      feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
      if (launcher != null) prLauncherProvider.overrideWithValue(launcher),
      authProvider.overrideWith(
        () => FakeAuthController(
          const AuthState(status: AuthStatus.signedIn, token: 'relayu_t'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/cards/RLY-A?board=relay&kind=$kind',
    routes: [
      GoRoute(
        path: '/cards/:ref',
        builder: (c, s) => CardScreen(
          cardRef: s.pathParameters['ref']!,
          boardSlug: s.uri.queryParameters['board'] ?? '',
          kind: s.uri.queryParameters['kind'],
          bodyBuilder: (_) => const Text('card body'),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: RelayTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a card with a pr_url shows the chip above the review bar', (
    tester,
  ) async {
    await pumpCard(
      tester,
      adapter: StubAdapter(
        body: summary('https://github.com/acme/relay/pull/42'),
      ),
    );

    expect(find.byKey(const Key('card_pr_chip')), findsOneWidget);
    expect(find.byKey(const Key('card_approve')), findsOneWidget);
  });

  testWidgets('the chip renders for a needs_input card with no review bar', (
    tester,
  ) async {
    await pumpCard(
      tester,
      adapter: StubAdapter(
        body: summary('https://github.com/acme/relay/pull/42'),
      ),
      kind: 'needs_input',
    );

    expect(find.byKey(const Key('card_pr_chip')), findsOneWidget);
    expect(find.byKey(const Key('card_approve')), findsNothing);
  });

  testWidgets('no pr_url — no chip, and the review bar is untouched', (
    tester,
  ) async {
    await pumpCard(tester, adapter: StubAdapter(body: summary(null)));

    expect(find.byKey(const Key('card_pr_chip')), findsNothing);
    expect(find.byKey(const Key('card_approve')), findsOneWidget);
  });

  testWidgets('a failed summary fetch degrades to no chip, not an error', (
    tester,
  ) async {
    await pumpCard(
      tester,
      adapter: StubAdapter(
        statusCode: 401,
        body: {
          'error': {'code': 'missing_token', 'message': 'no'},
        },
      ),
    );

    expect(find.byKey(const Key('card_pr_chip')), findsNothing);
    expect(find.byKey(const Key('card_approve')), findsOneWidget);
  });

  testWidgets('tap tries the GitHub app first; total failure gets a snackbar', (
    tester,
  ) async {
    final modes = <LaunchMode>[];
    final launcher = PrLauncher(
      launch: (uri, mode) async {
        modes.add(mode);
        return false;
      },
    );
    await pumpCard(
      tester,
      adapter: StubAdapter(
        body: summary('https://github.com/acme/relay/pull/42'),
      ),
      launcher: launcher,
    );

    await tester.tap(find.byKey(const Key('card_pr_chip')));
    await tester.pumpAndSettle();

    expect(modes, [
      LaunchMode.externalNonBrowserApplication,
      LaunchMode.inAppBrowserView,
    ]);
    expect(find.text("Couldn't open the PR."), findsOneWidget);
  });
}
