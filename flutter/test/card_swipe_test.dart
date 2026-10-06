import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

const _items = [
  CardNavItem(ref: 'RLY-1', boardSlug: 'relay'),
  CardNavItem(ref: 'RLY-2', boardSlug: 'relay', kind: 'in_review'),
  CardNavItem(ref: 'RLY-3', boardSlug: 'relay'),
];

CardNavContext _ctx(String at) =>
    CardNavContext.seed(items: _items, currentRef: at)!;

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
  WidgetBuilder? body,
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

Finder get _swipeArea => find.byKey(const Key('card_swipe_area'));

/// Stands in for the webview's side of the gesture arena. A platform view feeds
/// each pointer-down to the recognizers built from its `gestureRecognizers` and
/// only gets the touch once one of them wins — so this stub does exactly that with
/// the set the real InAppWebView is given, and counts the vertical drag updates
/// that would reach the page's scroll.
WidgetBuilder _webviewArenaStub(void Function() onVerticalUpdate) => (_) {
  final recognizers = [
    for (final f in CardScreen.webviewGestureRecognizersFor(
      mockupViewerOpen: false,
    ))
      f.constructor(),
  ];
  for (final r in recognizers) {
    if (r is VerticalDragGestureRecognizer) {
      r.onUpdate = (_) => onVerticalUpdate();
    }
  }
  return Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (e) {
      for (final r in recognizers) {
        r.addPointer(e);
      }
    },
    child: const SizedBox.expand(),
  );
};

/// The arena stub under two buttons that drive the viewer flag through
/// [CardScreen.setMockupViewerOpen] — the exact path the `relayMockupViewer` JS
/// callback takes.
Widget _viewerStubBody(BuildContext ctx) => Column(
  children: [
    TextButton(
      key: const Key('open_viewer'),
      onPressed: () => CardScreen.setMockupViewerOpen(ctx, true),
      child: const Text('open'),
    ),
    TextButton(
      key: const Key('close_viewer'),
      onPressed: () => CardScreen.setMockupViewerOpen(ctx, false),
      child: const Text('close'),
    ),
    Expanded(child: _webviewArenaStub(() {})(ctx)),
  ],
);

GestureDetector _swipeDetector(WidgetTester tester) =>
    tester.widget<GestureDetector>(_swipeArea);

void main() {
  testWidgets('swipe left advances to the next card in the column', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2');
    expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);

    await tester.drag(_swipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('card_body_RLY-3')), findsOneWidget);
  });

  testWidgets('a swiped-to card keeps the back label it was opened with', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2', back: 'Board');
    expect(
      tester.widget<CardScreen>(find.byType(CardScreen)).backLabel,
      'Board',
    );

    await tester.drag(_swipeArea, const Offset(-300, 0)); // → RLY-3
    await tester.pumpAndSettle();

    final screen = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(screen.cardRef, 'RLY-3');
    expect(screen.backLabel, 'Board');
  });

  testWidgets('swipe right returns to the previous card', (tester) async {
    await _pump(tester, at: 'RLY-2');

    await tester.drag(_swipeArea, const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('card_body_RLY-1')), findsOneWidget);
  });

  testWidgets('at the last card, swipe left is a no-op (no wrap, no crash)', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-3');

    await tester.drag(_swipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('card_body_RLY-3')), findsOneWidget);
  });

  testWidgets('a below-threshold drag does not navigate', (tester) async {
    await _pump(tester, at: 'RLY-2');

    await tester.drag(_swipeArea, const Offset(-20, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);
  });

  testWidgets("the landed card's kind drives the review bar", (tester) async {
    // RLY-2 is in_review → Approve/Reject bar; RLY-3 is not → no bar.
    await _pump(tester, at: 'RLY-2');
    expect(find.byKey(const Key('card_approve')), findsOneWidget);

    await tester.drag(_swipeArea, const Offset(-300, 0)); // → RLY-3
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('card_body_RLY-3')), findsOneWidget);
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
      expect(find.byKey(const ValueKey('card_body_RLY-3')), findsOneWidget);

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

    expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);
  });

  testWidgets('a vertical drag reaches the webview while the finger is down', (
    tester,
  ) async {
    // Regression: with only the horizontal swipe recognizer in the arena, a
    // vertical drag stayed unresolved until pointer-up, so the webview never got
    // it and the card body (mostly) would not scroll.
    var updates = 0;
    await _pump(tester, at: 'RLY-2', body: _webviewArenaStub(() => updates++));

    final gesture = await tester.startGesture(tester.getCenter(_swipeArea));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
    }

    expect(updates, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);
  });

  testWidgets('a horizontal swipe still navigates over the webview', (
    tester,
  ) async {
    await _pump(tester, at: 'RLY-2', body: _webviewArenaStub(() {}));

    await tester.drag(_swipeArea, const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('card_body_RLY-3')), findsOneWidget);
  });

  group('while the mockup viewer is open (RE393)', () {
    testWidgets('a horizontal drag does not change card', (tester) async {
      await _pump(tester, at: 'RLY-2', body: _viewerStubBody);

      await tester.tap(find.byKey(const Key('open_viewer')));
      await tester.pumpAndSettle();
      await tester.drag(_swipeArea, const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);
    });

    testWidgets('closing the viewer restores the card swipe', (tester) async {
      await _pump(tester, at: 'RLY-2', body: _viewerStubBody);
      await tester.tap(find.byKey(const Key('open_viewer')));
      await tester.pumpAndSettle();
      await tester.drag(_swipeArea, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);

      await tester.tap(find.byKey(const Key('close_viewer')));
      await tester.pumpAndSettle();
      await tester.drag(_swipeArea, const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('card_body_RLY-3')), findsOneWidget);
    });

    testWidgets('the swipe area enters no horizontal recognizer', (
      tester,
    ) async {
      await _pump(tester, at: 'RLY-2', body: _viewerStubBody);

      await tester.tap(find.byKey(const Key('open_viewer')));
      await tester.pumpAndSettle();
      expect(_swipeDetector(tester).onHorizontalDragStart, isNull);
      expect(_swipeDetector(tester).onHorizontalDragUpdate, isNull);
      expect(_swipeDetector(tester).onHorizontalDragEnd, isNull);

      await tester.tap(find.byKey(const Key('close_viewer')));
      await tester.pumpAndSettle();
      expect(_swipeDetector(tester).onHorizontalDragStart, isNotNull);
      expect(_swipeDetector(tester).onHorizontalDragUpdate, isNotNull);
      expect(_swipeDetector(tester).onHorizontalDragEnd, isNotNull);
    });

    testWidgets('a card change resets the viewer flag', (tester) async {
      final router = await _pump(
        tester,
        at: 'RLY-2',
        body: _viewerStubBody,
        stablePage: true,
      );
      await tester.tap(find.byKey(const Key('open_viewer')));
      await tester.pumpAndSettle();
      final before = tester.state(find.byType(CardScreen));

      router.pushReplacement('/cards/RLY-1?board=relay', extra: _ctx('RLY-1'));
      await tester.pumpAndSettle();
      // Same State, new card: only didUpdateWidget can have cleared the flag.
      expect(tester.state(find.byType(CardScreen)), same(before));
      await tester.drag(_swipeArea, const Offset(-300, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('card_body_RLY-2')), findsOneWidget);
    });
  });

  group('webviewGestureRecognizersFor', () {
    test('closed: exactly one VerticalDragGestureRecognizer', () {
      final built = [
        for (final f in CardScreen.webviewGestureRecognizersFor(
          mockupViewerOpen: false,
        ))
          f.constructor(),
      ];
      expect(built, hasLength(1));
      expect(built.single, isA<VerticalDragGestureRecognizer>());
    });

    test('open: exactly one EagerGestureRecognizer', () {
      final built = [
        for (final f in CardScreen.webviewGestureRecognizersFor(
          mockupViewerOpen: true,
        ))
          f.constructor(),
      ];
      expect(built, hasLength(1));
      expect(built.single, isA<EagerGestureRecognizer>());
    });
  });

  test('mockupViewerOpenFromArgs is true only for a leading literal true', () {
    expect(CardScreen.mockupViewerOpenFromArgs([true]), isTrue);
    expect(CardScreen.mockupViewerOpenFromArgs([false]), isFalse);
    expect(CardScreen.mockupViewerOpenFromArgs([]), isFalse);
    expect(CardScreen.mockupViewerOpenFromArgs(['true']), isFalse);
    expect(CardScreen.mockupViewerOpenFromArgs([1]), isFalse);
  });
}
