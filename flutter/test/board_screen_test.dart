import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/board/board_screen.dart';
import 'package:relay_mobile/features/boards/current_board.dart';

void main() {
  group('boardUrl', () {
    test('is the current board, embedded', () {
      expect(
        BoardScreen.boardUrl(
          baseUrl: 'https://relay.example',
          slug: 'marketing-site',
        ),
        'https://relay.example/board/marketing-site?embed=1',
      );
    });
  });

  test('the switcher bridge name matches the BoardPager hook (RE376)', () {
    // `flutter test` runs in flutter/, so the hook is one level up. This pins
    // the cross-language contract: rename one side and this fails.
    final js = File('../assets/js/hooks/board_pager.js').readAsStringSync();
    expect(js, contains('callHandler("${BoardScreen.openSwitcherHandler}"'));
  });

  group('slugFromPath', () {
    test('captures the slug from a visited board path', () {
      expect(
        BoardScreen.slugFromPath('/board/marketing-site'),
        'marketing-site',
      );
    });

    test('ignores everything that is not exactly /board/<slug>', () {
      // Only an exact board path is a board (the dead-board check).
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
        '/cards/RLY-7?board=demo&kind=in_review&back=Board',
      );
    });

    test('omits kind when the card is not at a gate', () {
      expect(
        BoardScreen.cardPathForTap({
          'ref': 'RLY-7',
          'board': 'demo',
          'kind': null,
        }),
        '/cards/RLY-7?board=demo&back=Board',
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

  testWidgets(
    'a board switch remounts the body — the webview reloads onto the new board (RE376)',
    (tester) async {
      var mounts = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('mkt')),
          ],
          child: MaterialApp(
            home: BoardScreen(
              bodyBuilder: (_) => _MountCounter(onMount: () => mounts++),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('board_body_mkt')), findsOneWidget);
      final before = mounts;

      final container = ProviderScope.containerOf(
        tester.element(find.byType(BoardScreen)),
      );
      await container.read(currentBoardProvider.notifier).switchTo('dat');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('board_body_dat')), findsOneWidget);
      expect(mounts, before + 1);
    },
  );
}

class _MountCounter extends StatefulWidget {
  const _MountCounter({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) =>
      const Text('board body', key: Key('stub_board_body'));
}
