import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/card/card_nav_context.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'review_queue_test.dart' show FakeDecisionApi, FakeFeedRepository;
import 'support/fake_auth.dart';

const _items = [
  CardNavItem(ref: 'RLY-1', boardSlug: 'relay'),
  CardNavItem(ref: 'RLY-2', boardSlug: 'relay', kind: 'in_review'),
  CardNavItem(ref: 'RLY-3', boardSlug: 'relay'),
];

CardNavContext _ctx(String at) =>
    CardNavContext.seed(items: _items, currentRef: at)!;

GoRouter _router() => GoRouter(
  initialLocation: '/start',
  routes: [
    GoRoute(
      path: '/start',
      builder: (c, s) =>
          const Scaffold(body: Text('inbox', key: Key('inbox_stub'))),
    ),
    GoRoute(
      path: '/cards/:ref',
      builder: (c, s) => CardScreen(
        cardRef: s.pathParameters['ref']!,
        boardSlug: s.uri.queryParameters['board'] ?? '',
        kind: s.uri.queryParameters['kind'],
        navContext: s.extra as CardNavContext?,
        bodyBuilder: (_) => const Text('card body', key: Key('stub_card_body')),
      ),
    ),
  ],
);

Future<GoRouter> _pump(
  WidgetTester tester, {
  required String at,
  bool withContext = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      decisionApiProvider.overrideWithValue(FakeDecisionApi()),
      feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
      authProvider.overrideWith(
        () => FakeAuthController(
          const AuthState(status: AuthStatus.signedIn, token: 'relayu_t'),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  final router = _router();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: RelayTheme.light, routerConfig: router),
    ),
  );
  final item = _items.firstWhere((i) => i.ref == at);
  final kindParam = item.kind == null ? '' : '&kind=${item.kind}';
  router.push(
    '/cards/$at?board=relay$kindParam',
    extra: withContext ? _ctx(at) : null,
  );
  await tester.pumpAndSettle();
  return router;
}

Finder get _swipeArea => find.byKey(const Key('card_swipe_area'));

void main() {
  testWidgets('swipe left advances to the next card in the column', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2');
    expect(find.widgetWithText(AppBar, 'RLY-2'), findsOneWidget);

    await tester.drag(_swipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'RLY-3'), findsOneWidget);
  });

  testWidgets('swipe right returns to the previous card', (tester) async {
    await _pump(tester, at: 'RLY-2');

    await tester.drag(_swipeArea, const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'RLY-1'), findsOneWidget);
  });

  testWidgets('at the last card, swipe left is a no-op (no wrap, no crash)', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-3');

    await tester.drag(_swipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'RLY-3'), findsOneWidget);
  });

  testWidgets('a below-threshold drag does not navigate', (tester) async {
    await _pump(tester, at: 'RLY-2');

    await tester.drag(_swipeArea, const Offset(-20, 0));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'RLY-2'), findsOneWidget);
  });

  testWidgets("the landed card's kind drives the review bar", (tester) async {
    // RLY-2 is in_review → Approve/Reject bar; RLY-3 is not → no bar.
    await _pump(tester, at: 'RLY-2');
    expect(find.byKey(const Key('card_approve')), findsOneWidget);

    await tester.drag(_swipeArea, const Offset(-300, 0)); // → RLY-3
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'RLY-3'), findsOneWidget);
    expect(find.byKey(const Key('card_approve')), findsNothing);
  });

  testWidgets(
    'Back after swiping returns to the origin list, not a prior card',
    (tester) async {
      final router = await _pump(tester, at: 'RLY-1');
      await tester.drag(_swipeArea, const Offset(-300, 0)); // → RLY-2
      await tester.pumpAndSettle();
      await tester.drag(_swipeArea, const Offset(-300, 0)); // → RLY-3
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'RLY-3'), findsOneWidget);

      router.pop(); // device back
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
    },
  );

  testWidgets('with no nav context (cold deep link) swipe is inert', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2', withContext: false);

    await tester.drag(_swipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'RLY-2'), findsOneWidget);
  });
}
