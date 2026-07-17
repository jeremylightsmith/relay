import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_screen.dart';

void main() {
  group('boardUrl', () {
    test('is the slugless default-board redirect in embed mode', () {
      // RelayWeb.Plugs.Embed promotes ?embed=1 into the session before the
      // redirect resolves the default board, so the slug URL stays chromeless.
      expect(
        BoardScreen.boardUrl(baseUrl: 'https://relay.example'),
        'https://relay.example/board?embed=1',
      );
    });
  });

  group('cardPathForTap', () {
    test('routes ref + board + kind to the native card host', () {
      expect(
        BoardScreen.cardPathForTap({
          'ref': 'RLY-7',
          'board': 'demo',
          'kind': 'in_review',
        }),
        '/cards/RLY-7?board=demo&kind=in_review',
      );
    });

    test('omits kind when the card is not at a gate', () {
      expect(
        BoardScreen.cardPathForTap({
          'ref': 'RLY-7',
          'board': 'demo',
          'kind': null,
        }),
        '/cards/RLY-7?board=demo',
      );
    });

    test('is null without a ref — nothing to route to', () {
      expect(BoardScreen.cardPathForTap(const {}), isNull);
      expect(BoardScreen.cardPathForTap({'ref': '', 'board': 'demo'}), isNull);
    });
  });

  testWidgets(
    'the Board tab hosts the webview body chromeless (no native AppBar)',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BoardScreen(
            bodyBuilder: (_) =>
                const Text('board body', key: Key('stub_board_body')),
          ),
        ),
      );

      expect(find.byKey(const Key('stub_board_body')), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
    },
  );
}
