import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/messenger.dart';
import 'package:relay_mobile/features/card/card_nav_context.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/card/widgets/card_review_bar.dart';

import 'card_screen_wiring_test.dart' show pumpCardHost;
import 'review_queue_test.dart' show FakeDecisionApi;

/// RE393 — the web nav bar owns the card's top bar; its back control calls the
/// `relayNavBack` JS handler, which lands in [CardScreen.navBack].
GoRouter _router(String initialLocation) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/needs-you',
      builder: (c, s) =>
          const Scaffold(body: Text('inbox', key: Key('inbox_stub'))),
    ),
    GoRoute(
      path: '/cards/:ref',
      builder: (c, s) =>
          const Scaffold(body: Text('card', key: Key('card_stub'))),
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  GoRouter router, {
  GlobalKey<ScaffoldMessengerState>? messenger,
}) async {
  await tester.pumpWidget(
    MaterialApp.router(routerConfig: router, scaffoldMessengerKey: messenger),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('navBack pops a pushed card back to where it came from', (
    tester,
  ) async {
    final router = _router('/needs-you');
    await _pump(tester, router);
    router.push('/cards/RLY-1?board=b&back=Needs+you');
    await tester.pumpAndSettle();
    expect(router.canPop(), isTrue);

    CardScreen.navBack(router);
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/needs-you');
    expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
    expect(router.canPop(), isFalse, reason: 'popped, not pushed on top');
  });

  testWidgets('navBack on an orphan push deep link goes to Needs you', (
    tester,
  ) async {
    final router = _router('/cards/RLY-1?board=b');
    await _pump(tester, router);
    expect(router.canPop(), isFalse);

    CardScreen.navBack(router);
    await tester.pumpAndSettle();

    expect(router.state.uri.path, '/needs-you');
    expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
  });

  group('relayNavBack with a message (RE498)', () {
    test('the message decodes from a leading non-blank String', () {
      expect(
        CardScreen.navBackMessageFromArgs(['RE498 archived']),
        'RE498 archived',
      );
      expect(
        CardScreen.navBackMessageFromArgs(['  RE498 was archived  ']),
        'RE498 was archived',
        reason: 'returned trimmed',
      );
    });

    test('a malformed or empty call decodes to no message', () {
      for (final args in <List<dynamic>>[
        [],
        [42],
        [null],
        [''],
        ['   '],
        [
          {'message': 'x'},
        ],
      ]) {
        expect(
          CardScreen.navBackMessageFromArgs(args),
          isNull,
          reason: '$args',
        );
      }
    });

    Future<GoRouter> pushedCard(
      WidgetTester tester,
      GlobalKey<ScaffoldMessengerState> messenger,
    ) async {
      final router = _router('/needs-you');
      await _pump(tester, router, messenger: messenger);
      router.push('/cards/RLY-1?board=b&back=Board');
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('pops and toasts the message over the destination', (
      tester,
    ) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final router = await pushedCard(tester, messenger);

      CardScreen.navBack(
        router,
        messenger: messenger,
        message: 'RLY-1 archived',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Settle the route transition: until the card route is gone its Scaffold
      // also renders the app messenger's SnackBar.
      await tester.pumpAndSettle();

      expect(router.state.uri.path, '/needs-you');
      final toast = find.byKey(CardScreen.leftToastKey);
      expect(toast, findsOneWidget);
      expect(find.text('RLY-1 archived'), findsOneWidget);
      expect(
        tester.widget<SnackBar>(toast).duration,
        toastDuration,
        reason: "the app's one toast, not a raw SnackBar",
      );
    });

    testWidgets('an orphan deep link goes to Needs you and toasts', (
      tester,
    ) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final router = _router('/cards/RLY-1?board=b');
      await _pump(tester, router, messenger: messenger);
      expect(router.canPop(), isFalse);

      CardScreen.navBack(
        router,
        messenger: messenger,
        message: 'RLY-1 was archived',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Settle the route transition: until the card route is gone its Scaffold
      // also renders the app messenger's SnackBar.
      await tester.pumpAndSettle();

      expect(router.state.uri.path, '/needs-you');
      expect(find.byKey(CardScreen.leftToastKey), findsOneWidget);
      expect(find.text('RLY-1 was archived'), findsOneWidget);
    });

    testWidgets('with a messenger but no message pops with no toast', (
      tester,
    ) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final router = await pushedCard(tester, messenger);

      CardScreen.navBack(router, messenger: messenger);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, '/needs-you');
      expect(find.byKey(CardScreen.leftToastKey), findsNothing);
    });

    testWidgets('with no messenger pops with no toast', (tester) async {
      final messenger = GlobalKey<ScaffoldMessengerState>();
      final router = await pushedCard(tester, messenger);

      CardScreen.navBack(router);
      await tester.pumpAndSettle();

      expect(router.state.uri.path, '/needs-you');
      expect(find.byKey(CardScreen.leftToastKey), findsNothing);
    });
  });

  testWidgets('the card host draws no native AppBar or back button', (
    tester,
  ) async {
    await pumpCardHost(tester, api: FakeDecisionApi());

    expect(find.byType(CardScreen), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const Key('card_back')), findsNothing);
    expect(find.byType(CardReviewBar), findsOneWidget);
  });

  test('the JS handler name pins the web nav bar contract', () {
    expect(CardScreen.navBackHandler, 'relayNavBack');
  });

  test('the card nav JS handler name pins the web chevron contract', () {
    expect(CardScreen.cardNavHandler, 'relayCardNav');
  });

  test('the card nav direction names are the wire tokens', () {
    expect(CardNavDirection.prev.name, 'prev');
    expect(CardNavDirection.next.name, 'next');
  });
}
