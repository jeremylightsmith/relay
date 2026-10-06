import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

Future<void> _pump(WidgetTester tester, GoRouter router) async {
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
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
}
