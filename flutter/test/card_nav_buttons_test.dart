import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/card/card_nav_context.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/card/card_summary.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'review_queue_test.dart' show FakeDecisionApi, FakeFeedRepository;
import 'support/fake_auth.dart';

/// RE400: the web drawer's ‹ › chevrons call `relayCardNav`, whose callback lands
/// in [CardScreen.navigate]. The real webview can't build under `flutter test`,
/// so a stub body drives the same static entry point.

const _items = [
  CardNavItem(ref: 'RLY-1', boardSlug: 'relay'),
  CardNavItem(ref: 'RLY-2', boardSlug: 'relay', kind: 'in_review'),
  CardNavItem(ref: 'RLY-3', boardSlug: 'relay'),
];

CardNavContext _ctx(String at) =>
    CardNavContext.seed(items: _items, currentRef: at)!;

/// Two buttons standing in for the web chevrons — the exact path the
/// `relayCardNav` JS callback takes.
Widget _navStubBody(BuildContext ctx) => Column(
  children: [
    TextButton(
      key: const Key('nav_prev'),
      onPressed: () => CardScreen.navigate(ctx, CardNavDirection.prev),
      child: const Text('‹'),
    ),
    TextButton(
      key: const Key('nav_next'),
      onPressed: () => CardScreen.navigate(ctx, CardNavDirection.next),
      child: const Text('›'),
    ),
  ],
);

GoRouter _router({WidgetBuilder? body, bool stablePage = false}) => GoRouter(
  initialLocation: '/start',
  routes: [
    GoRoute(
      path: '/start',
      builder: (c, s) =>
          const Scaffold(body: Text('inbox', key: Key('inbox_stub'))),
    ),
    GoRoute(
      path: '/cards/:ref',
      // stablePage keys the page by the route alone, so a pushReplacement to
      // another card updates the same CardScreen State (didUpdateWidget) instead
      // of mounting a fresh one.
      pageBuilder: (c, s) => MaterialPage(
        key: stablePage ? const ValueKey('card_page') : s.pageKey,
        child: CardScreen(
          cardRef: s.pathParameters['ref']!,
          boardSlug: s.uri.queryParameters['board'] ?? '',
          kind: s.uri.queryParameters['kind'],
          backLabel: s.uri.queryParameters['back'],
          navContext: s.extra as CardNavContext?,
          bodyBuilder:
              body ??
              (_) => const Text('card body', key: Key('stub_card_body')),
        ),
      ),
    ),
  ],
);

Future<GoRouter> _pump(
  WidgetTester tester, {
  required String at,
  bool withContext = true,
  String? back,
  WidgetBuilder? body = _navStubBody,
  bool stablePage = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      decisionApiProvider.overrideWithValue(FakeDecisionApi()),
      feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
      // No PR chip here: an in-place card update (stablePage) would otherwise
      // leave the summary fetch's timer pending at teardown.
      cardPrUrlProvider.overrideWith((ref, key) async => null),
      authProvider.overrideWith(
        () => FakeAuthController(
          const AuthState(status: AuthStatus.signedIn, token: 'relayu_t'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = _router(body: body, stablePage: stablePage);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: RelayTheme.light, routerConfig: router),
    ),
  );
  final item = _items.firstWhere((i) => i.ref == at);
  final kindParam = item.kind == null ? '' : '&kind=${item.kind}';
  final backParam = back == null
      ? ''
      : '&back=${Uri.encodeQueryComponent(back)}';
  router.push(
    '/cards/$at?board=relay$kindParam$backParam',
    extra: withContext ? _ctx(at) : null,
  );
  await tester.pumpAndSettle();
  return router;
}

Finder _body(String ref) => find.byKey(ValueKey('card_body_$ref'));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('cardNavDirectionFromArgs', () {
    test("['prev'] decodes to prev", () {
      expect(
        CardScreen.cardNavDirectionFromArgs(['prev']),
        CardNavDirection.prev,
      );
    });

    test("['next'] decodes to next", () {
      expect(
        CardScreen.cardNavDirectionFromArgs(['next']),
        CardNavDirection.next,
      );
    });

    test('anything else decodes to null', () {
      for (final args in <List<dynamic>>[
        [],
        ['Prev'],
        ['up'],
        [1],
        [null],
        [true],
      ]) {
        expect(
          CardScreen.cardNavDirectionFromArgs(args),
          isNull,
          reason: '$args',
        );
      }
    });
  });

  testWidgets('› moves to the next card in the context', (tester) async {
    await _pump(tester, at: 'RLY-2');
    expect(_body('RLY-2'), findsOneWidget);

    await _tap(tester, 'nav_next');

    expect(_body('RLY-3'), findsOneWidget);
  });

  testWidgets('‹ moves to the previous card in the context', (tester) async {
    await _pump(tester, at: 'RLY-2');

    await _tap(tester, 'nav_prev');

    expect(_body('RLY-1'), findsOneWidget);
  });

  testWidgets('the landed card keeps the back label it was opened with', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2', back: 'Board');

    await _tap(tester, 'nav_next');

    final screen = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(screen.cardRef, 'RLY-3');
    expect(screen.backLabel, 'Board');
  });

  testWidgets("the landed card's kind drives the review bar", (tester) async {
    // RLY-2 is in_review → Approve/Reject bar; RLY-3 is not → no bar.
    await _pump(tester, at: 'RLY-2');
    expect(find.byKey(const Key('card_approve')), findsOneWidget);

    await _tap(tester, 'nav_next');

    expect(_body('RLY-3'), findsOneWidget);
    expect(find.byKey(const Key('card_approve')), findsNothing);
  });

  testWidgets('Back after ‹ › returns to the origin list, not a prior card', (
    tester,
  ) async {
    final router = await _pump(tester, at: 'RLY-1');
    await _tap(tester, 'nav_next'); // → RLY-2
    await _tap(tester, 'nav_next'); // → RLY-3
    expect(_body('RLY-3'), findsOneWidget);

    router.pop(); // device back
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
  });

  testWidgets('› at the last card is a no-op (no wrap, no crash)', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-3');

    await _tap(tester, 'nav_next');

    expect(_body('RLY-3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('‹ at the first card is a no-op', (tester) async {
    await _pump(tester, at: 'RLY-1');

    await _tap(tester, 'nav_prev');

    expect(_body('RLY-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with no nav context (cold deep link) › is inert', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2', withContext: false);

    await _tap(tester, 'nav_next');

    expect(_body('RLY-2'), findsOneWidget);
  });

  testWidgets('a sideways drag on the body never changes card', (tester) async {
    await _pump(tester, at: 'RLY-2', body: null);
    expect(find.byKey(const Key('card_swipe_area')), findsNothing);

    await tester.drag(_body('RLY-2'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(_body('RLY-2'), findsOneWidget);

    await tester.drag(_body('RLY-2'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(_body('RLY-2'), findsOneWidget);
  });

  testWidgets('› works when go_router reuses the CardScreen State', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2', stablePage: true);
    final before = tester.state(find.byType(CardScreen));

    await _tap(tester, 'nav_next');

    expect(tester.state(find.byType(CardScreen)), same(before));
    expect(_body('RLY-3'), findsOneWidget);
  });
}
