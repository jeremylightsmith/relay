import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/board/board_screen.dart';

void main() {
  group('boardUrl', () {
    test('opens the remembered board when a slug is stored', () {
      expect(
        BoardScreen.boardUrl(
          baseUrl: 'https://relay.example',
          slug: 'marketing-site',
        ),
        'https://relay.example/board/marketing-site?embed=1',
      );
    });

    test('falls back to the boards list when nothing is stored', () {
      // RLY-95 decision 4: no server-picked default — BOARDS-00 precedes BOARD-01,
      // so a fresh sign-in lands on the list, not /board's redirect.
      expect(
        BoardScreen.boardUrl(baseUrl: 'https://relay.example'),
        'https://relay.example/boards?embed=1',
      );
      expect(
        BoardScreen.boardUrl(baseUrl: 'https://relay.example', slug: ''),
        'https://relay.example/boards?embed=1',
      );
    });
  });

  group('slugFromPath', () {
    test('captures the slug from a visited board path', () {
      expect(
        BoardScreen.slugFromPath('/board/marketing-site'),
        'marketing-site',
      );
    });

    test('ignores everything that is not exactly /board/<slug>', () {
      // Visiting /boards must NOT clear or rebind the remembered pick.
      expect(BoardScreen.slugFromPath('/boards'), isNull);
      expect(BoardScreen.slugFromPath('/board'), isNull);
      expect(
        BoardScreen.slugFromPath('/board/marketing-site/settings'),
        isNull,
      );
      expect(BoardScreen.slugFromPath('/cards/RLY-7'), isNull);
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

  group('navContextForTap', () {
    test(
      'parses the column into an ordered context seeked to the tapped ref',
      () {
        final ctx = BoardScreen.navContextForTap({
          'ref': 'RLY-2',
          'board': 'demo',
          'kind': 'in_review',
          'cards': [
            {'ref': 'RLY-1', 'kind': null},
            {'ref': 'RLY-2', 'kind': 'in_review'},
            {'ref': 'RLY-3', 'kind': null},
          ],
        });
        expect(ctx, isNotNull);
        expect(ctx!.index, 1);
        expect(ctx.prev?.ref, 'RLY-1');
        expect(ctx.next?.ref, 'RLY-3');
        expect(ctx.next?.boardSlug, 'demo');
        expect(ctx.next?.kind, isNull);
      },
    );

    test('is null without a cards list — a plain tap carries no column', () {
      expect(
        BoardScreen.navContextForTap({'ref': 'RLY-2', 'board': 'demo'}),
        isNull,
      );
    });
  });

  testWidgets(
    'the Board tab hosts the webview body chromeless (no native AppBar)',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs()),
          ],
          child: MaterialApp(
            home: BoardScreen(
              bodyBuilder: (_) =>
                  const Text('board body', key: Key('stub_board_body')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stub_board_body')), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
    },
  );
}
