import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/decisions/reject_note_screen.dart';
import 'package:relay_mobile/features/push/push_platform.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';

import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';

// `pathForPayload` and `CardScreen.cardUrl` are pure functions — unit-tested
// below without pumping anything.

/// The card route with a stub body: flutter_inappwebview has no host-platform
/// implementation, so the real webview cannot build under `flutter test`.
Future<GoRouter> pumpRouter(WidgetTester tester) async {
  final router = buildRouter(
    cardBodyBuilder: (_) => const SizedBox.shrink(key: Key('stub_card_body')),
  );
  await tester.pumpWidget(
    ProviderScope(
      // /push-permission now gates itself on the OS status + the deferral
      // (RLY-84 §1), so this route needs both seams faked. Without them the gate
      // reads a real IosPushPrefs over an unmocked MethodChannel, throws, and
      // fail-safes to skip — the screen would never render.
      overrides: [
        pushPlatformProvider.overrideWithValue(
          FakePushPlatform(status: PushAuthorizationStatus.notDetermined),
        ),
        pushPrefsProvider.overrideWithValue(FakePushPrefs()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('a notification tap routes to the card screen', (tester) async {
    final router = await pumpRouter(tester);

    // What the tap handler does with a {card_ref, board_slug} payload.
    router.go('/cards/RLY-123?board=my-board');
    await tester.pumpAndSettle();

    final screen = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(screen.cardRef, 'RLY-123');
    expect(screen.boardSlug, 'my-board');
  });

  testWidgets(
    'a reject deep link routes to RejectNoteScreen carrying ref and board '
    '(RLY-88 · CORE-07)',
    (tester) async {
      final router = await pumpRouter(tester);

      router.go('/card/RLY-A/reject?board=relay');
      await tester.pumpAndSettle();

      final screen = tester.widget<RejectNoteScreen>(
        find.byType(RejectNoteScreen),
      );
      expect(screen.cardRef, 'RLY-A');
      expect(screen.boardSlug, 'relay');
    },
  );

  testWidgets('the push permission screen is routable', (tester) async {
    final router = await pumpRouter(tester);

    router.go('/push-permission');
    await tester.pumpAndSettle();

    expect(find.text('Let Relay reach you'), findsOneWidget);
  });

  test('cardUrl builds the embedded LiveView deep link', () {
    expect(
      CardScreen.cardUrl(
        cardRef: 'RLY-123',
        boardSlug: 'my-board',
        baseUrl: 'http://localhost:4003',
      ),
      'http://localhost:4003/board/my-board?card=RLY-123&embed=1',
    );
  });

  test('pathForPayload maps a push payload to a route', () {
    expect(
      pathForPayload({
        'card_ref': 'RLY-9',
        'board_slug': 'b1',
        'kind': 'in_review',
      }),
      '/cards/RLY-9?board=b1',
    );
    expect(pathForPayload({'kind': 'in_review'}), isNull);
  });

  test(
    'pathForPayload ignores `kind` — every push routes to the card (RLY-86 §8)',
    () {
      // Routing on `kind` is exactly what breaks when a push is stale: a card that was
      // :needs_input at send time and :in_review at tap time would open the answer
      // surface for a question that no longer exists. The card's *current* state picks
      // the surface (RLY-87), which makes stale-push handling free.
      const card = {'card_ref': 'RLY-9', 'board_slug': 'b1'};

      expect(
        pathForPayload({...card, 'kind': 'needs_input'}),
        pathForPayload({...card, 'kind': 'in_review'}),
      );
      expect(
        pathForPayload({...card, 'kind': 'needs_input'}),
        '/cards/RLY-9?board=b1',
      );
    },
  );
}
