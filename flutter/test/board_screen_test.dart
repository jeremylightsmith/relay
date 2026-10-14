import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/tabs.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/board/board_screen.dart';
import 'package:relay_mobile/features/board/last_place.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository;
import 'support/fake_boards.dart';

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

    test('appends the requested stage page (RE452)', () {
      expect(
        BoardScreen.boardUrl(
          baseUrl: 'https://r.test',
          slug: 'relay',
          stageId: 12,
        ),
        'https://r.test/board/relay?embed=1&stage=12',
      );
      expect(
        BoardScreen.boardUrl(
          baseUrl: 'https://r.test',
          slug: 'relay',
          stageId: null,
        ),
        'https://r.test/board/relay?embed=1',
      );
    });
  });

  test('the switcher bridge name matches the BoardPager hook (RE376)', () {
    // `flutter test` runs in flutter/, so the hook is one level up. This pins
    // the cross-language contract: rename one side and this fails.
    final js = File('../assets/js/hooks/board_pager.js').readAsStringSync();
    expect(js, contains('callHandler("${BoardScreen.openSwitcherHandler}"'));
  });

  test('the stage bridge names match the BoardPager hook (RE452)', () {
    expect(BoardScreen.stageChangedHandler, 'relayStageChanged');
    expect(BoardScreen.stageMissingHandler, 'relayStageMissing');
    final js = File('../assets/js/hooks/board_pager.js').readAsStringSync();
    expect(js, contains('callHandler("${BoardScreen.stageChangedHandler}"'));
    expect(js, contains('callHandler("${BoardScreen.stageMissingHandler}"'));
  });

  group('onStageChanged (RE452)', () {
    late WidgetRef ref;
    late ProviderContainer container;

    Future<void> pumpRef(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('relay')),
            lastPlaceStoreProvider.overrideWithValue(InMemoryLastPlaceStore()),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      await container.read(currentBoardProvider.notifier).ready;
      await container.read(lastPlaceProvider.notifier).ready;
    }

    LastPlace? place() => container.read(lastPlaceProvider).place;

    testWidgets('records the current board\'s stage page', (tester) async {
      await pumpRef(tester);

      BoardScreen.onStageChanged(ref, {
        'board': 'relay',
        'stage_id': 12,
        'stage_name': 'Spec',
      });

      expect(
        place(),
        const LastPlace(tab: AppTab.board, stageId: 12, stageName: 'Spec'),
      );
    });

    testWidgets('ignores another board, a missing id and a non-numeric id', (
      tester,
    ) async {
      await pumpRef(tester);
      BoardScreen.onStageChanged(ref, {
        'board': 'relay',
        'stage_id': 12,
        'stage_name': 'Spec',
      });
      final before = place();

      for (final payload in <Map<dynamic, dynamic>>[
        {'board': 'other', 'stage_id': 13, 'stage_name': 'Code'},
        {'board': 'relay', 'stage_name': 'Code'},
        {'board': 'relay', 'stage_id': 'x', 'stage_name': 'Code'},
      ]) {
        BoardScreen.onStageChanged(ref, payload);
        expect(place(), before, reason: '$payload');
      }
    });

    testWidgets('accepts a numeric-string stage id', (tester) async {
      await pumpRef(tester);

      BoardScreen.onStageChanged(ref, {
        'board': 'relay',
        'stage_id': '14',
        'stage_name': 'Code',
      });

      expect(place()?.stageId, 14);
      expect(place()?.stageName, 'Code');
    });
  });

  group('the /board route (RE452)', () {
    Future<GoRouter> pumpRouter(WidgetTester tester) async {
      final router = buildRouter(
        boardBodyBuilder: (_) =>
            const Text('board body', key: Key('stub_board_body')),
        cardBodyBuilder: (_) =>
            const Text('card body', key: Key('stub_card_body')),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardsRepositoryProvider.overrideWithValue(FakeBoardsRepository()),
            boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('relay')),
            feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
            lastPlaceStoreProvider.overrideWithValue(InMemoryLastPlaceStore()),
            authTokenProvider.overrideWithValue('relayu_test'),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    int? stageIdAt(WidgetTester tester) =>
        tester.widget<BoardScreen>(find.byType(BoardScreen)).stageId;

    testWidgets('passes ?stage= through as the stage id', (tester) async {
      final router = await pumpRouter(tester);
      router.go('/board?stage=12');
      await tester.pumpAndSettle();
      expect(stageIdAt(tester), 12);
    });

    BoardScreenState boardState(WidgetTester tester) =>
        tester.state<BoardScreenState>(find.byType(BoardScreen));

    // The smoke repro: a card restore loads the board UNDER the pushed card,
    // where its stage scroll and reports run with no real layout.
    testWidgets(
      'a board under a pushed card drops stage reports, and re-shows its stage on pop',
      (tester) async {
        final router = await pumpRouter(tester);
        router.go('/board?stage=12');
        await tester.pumpAndSettle();
        final state = boardState(tester);
        expect(state.stageGate.visible, isTrue);

        unawaited(
          router.push(
            BoardScreen.cardPathForTap({'ref': 'MA3', 'board': 'relay'})!,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('stub_card_body')), findsOneWidget);
        expect(state.stageGate.visible, isFalse);
        expect(
          state.stageGate.accept(30),
          isFalse,
          reason: 'a hidden page report is not what the user sees',
        );
        expect(state.shownStages, isEmpty);

        router.pop();
        await tester.pumpAndSettle();

        expect(state.stageGate.visible, isTrue);
        expect(state.shownStages, [12]);
      },
    );

    testWidgets('a pop re-shows the page last seen, not the requested one', (
      tester,
    ) async {
      final router = await pumpRouter(tester);
      router.go('/board?stage=12');
      await tester.pumpAndSettle();
      final state = boardState(tester);
      expect(state.stageGate.accept(20), isTrue);

      unawaited(
        router.push(
          BoardScreen.cardPathForTap({'ref': 'MA3', 'board': 'relay'})!,
        ),
      );
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(state.shownStages, [20]);
    });

    testWidgets('a non-integer or missing stage is null', (tester) async {
      final router = await pumpRouter(tester);
      router.go('/board?stage=abc');
      await tester.pumpAndSettle();
      expect(stageIdAt(tester), isNull);

      router.go('/board');
      await tester.pumpAndSettle();
      expect(stageIdAt(tester), isNull);
    });
  });

  group('BoardStageGate (RE452)', () {
    test(
      'keeps reports while visible and re-shows nothing without a reveal',
      () {
        final gate = BoardStageGate(requestedStageId: 12);
        expect(gate.accept(12), isTrue);
        expect(gate.setVisible(true), isNull);
      },
    );

    test(
      'drops reports while hidden; a reveal re-shows the requested stage',
      () {
        final gate = BoardStageGate(requestedStageId: 12);
        expect(gate.setVisible(false), isNull);
        expect(gate.accept(30), isFalse);
        expect(gate.setVisible(true), 12);
      },
    );

    test('a reveal re-shows the last page seen on screen', () {
      final gate = BoardStageGate(requestedStageId: 12);
      gate.accept(20);
      gate.setVisible(false);
      gate.accept(30);
      expect(gate.setVisible(true), 20);
    });

    test('no stage requested or seen: a reveal re-shows nothing', () {
      final gate = BoardStageGate(requestedStageId: null);
      gate.setVisible(false);
      expect(gate.setVisible(true), isNull);
    });
  });

  test(
    'showStageScript dispatches the event the BoardPager hook listens for',
    () {
      expect(
        BoardScreen.showStageScript(12),
        contains(
          'new CustomEvent("relay:show-stage", {detail: {stage_id: 12}})',
        ),
      );
      final js = File('../assets/js/hooks/board_pager.js').readAsStringSync();
      expect(js, contains('"${BoardScreen.showStageEvent}"'));
    },
  );

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

  testWidgets(
    'a stage param does not remount the body — the webview key is slug-only (RE452)',
    (tester) async {
      var mounts = 0;
      Widget screen(int stageId) => ProviderScope(
        overrides: [
          boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('relay')),
        ],
        child: MaterialApp(
          home: BoardScreen(
            stageId: stageId,
            bodyBuilder: (_) => _MountCounter(onMount: () => mounts++),
          ),
        ),
      );

      await tester.pumpWidget(screen(12));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('board_body_relay')), findsOneWidget);
      final before = mounts;

      await tester.pumpWidget(screen(20));
      await tester.pumpAndSettle();

      expect(mounts, before);
      expect(find.byKey(const ValueKey('board_body_relay')), findsOneWidget);
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
