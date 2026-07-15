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

    // What the tap handler does with a {card_ref, board_slug, kind} payload.
    router.go('/cards/RLY-123?board=my-board&kind=in_review');
    await tester.pumpAndSettle();

    final screen = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(screen.cardRef, 'RLY-123');
    expect(screen.boardSlug, 'my-board');
    expect(screen.kind, 'in_review');
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
      'http://localhost:4003/cards/RLY-123?board=my-board&embed=1',
    );
  });

  test('pathForPayload maps a push payload to a route', () {
    expect(
      pathForPayload({
        'card_ref': 'RLY-9',
        'board_slug': 'b1',
        'kind': 'in_review',
      }),
      '/cards/RLY-9?board=b1&kind=in_review',
    );
    expect(pathForPayload({'kind': 'in_review'}), isNull);
  });

  test(
    'pathForPayload carries `kind` so a push tap lands on the right bar (RLY-87 §5)',
    () {
      // Supersedes RLY-86 §8, which dropped `kind` so the card's current state could pick
      // the surface. RLY-87 is surface-only and does no fetch, so the payload's kind is
      // what the host has. A stale push therefore shows the wrong bar — accepted here
      // (the actions are stubbed) and RLY-88's to handle.
      const card = {'card_ref': 'RLY-9', 'board_slug': 'b1'};

      expect(
        pathForPayload({...card, 'kind': 'needs_input'}),
        '/cards/RLY-9?board=b1&kind=needs_input',
      );
      expect(
        pathForPayload({...card, 'kind': 'in_review'}),
        '/cards/RLY-9?board=b1&kind=in_review',
      );
      // No kind in an older payload in flight: no bar, rather than the wrong one.
      expect(pathForPayload(card), '/cards/RLY-9?board=b1');
    },
  );
}
