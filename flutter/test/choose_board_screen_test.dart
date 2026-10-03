import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/choose_board_screen.dart';
import 'package:relay_mobile/features/boards/widgets/board_row.dart';

import 'support/fake_boards.dart';

Future<void> pumpChoose(WidgetTester tester, FakeBoardsRepository repo) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        boardsRepositoryProvider.overrideWithValue(repo),
        boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs()),
        authTokenProvider.overrideWithValue('relayu_t'),
      ],
      child: MaterialApp(
        theme: RelayTheme.light,
        home: const ChooseBoardScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // BOARDS-00 · card mockup "B — always in one board, switch from the title".
  testWidgets('heading, subtitle, and one row per board with counts and meta', (
    tester,
  ) async {
    await pumpChoose(
      tester,
      FakeBoardsRepository(
        boards: [
          makeBoard(
            'marketing-site',
            name: 'Marketing site',
            needsYou: 2,
            stages: 6,
            cards: 11,
          ),
          makeBoard(
            'support-triage',
            name: 'Support triage',
            stages: 3,
            cards: 2,
            aiActive: false,
          ),
        ],
      ),
    );

    final heading = tester.widget<Text>(
      find.byKey(const Key('choose_board_title')),
    );
    expect(heading.data, 'Choose a board');
    expect(heading.style?.fontSize, 28);
    expect(heading.style?.fontWeight, FontWeight.w700);
    expect(
      tester.widget<Text>(find.byKey(const Key('choose_board_subtitle'))).data,
      'You can switch any time from the title.',
    );

    final subtitle = tester.widget<Text>(
      find.byKey(const Key('choose_board_subtitle')),
    );
    final scheme = RelayTheme.light.colorScheme;
    expect(subtitle.style?.fontSize, 15);
    expect(subtitle.style?.color, scheme.onSurfaceVariant);

    // Row: rounded-xl border-base-300 p-3 → radius 12, outlineVariant, padding 12.
    final surface = tester.widget<Material>(
      find.byKey(const Key('board_row_surface_support-triage')),
    );
    final shape = surface.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(12));
    expect(shape.side.color, scheme.outlineVariant);
    final padding = tester.widget<Padding>(
      find
          .descendant(
            of: find.byKey(const Key('board_row_support-triage')),
            matching: find.byType(Padding),
          )
          .first,
    );
    expect(padding.padding, const EdgeInsets.all(12));

    // Name: font-semibold text-[14px].
    final name = tester.widget<Text>(find.text('Marketing site'));
    expect(name.style?.fontSize, 14);
    expect(name.style?.fontWeight, FontWeight.w600);

    // Meta: font-mono text-[10.5px] text-base-content/55.
    final meta = tester.widget<Text>(
      find.byKey(const Key('board_row_meta_marketing-site')),
    );
    expect(meta.style?.fontFamily, 'monospace');
    expect(meta.style?.fontSize, 10.5);
    expect(meta.style?.color, scheme.onSurfaceVariant);

    expect(find.text('Marketing site'), findsOneWidget);
    expect(find.text('2 needs you'), findsOneWidget);
    // 0 → no badge at all (the mockup's Support triage row).
    expect(
      find.byKey(const Key('board_row_needs_you_support-triage')),
      findsNothing,
    );
    expect(find.text('6 stages · 11 cards · AI active'), findsOneWidget);
    expect(find.text('3 stages · 2 cards · idle'), findsOneWidget);
    // Choose a board marks nothing current.
    expect(find.text('✓'), findsNothing);
  });

  testWidgets('zero boards: says to create one on the web', (tester) async {
    await pumpChoose(tester, FakeBoardsRepository());

    expect(find.byKey(const Key('choose_board_empty')), findsOneWidget);
    expect(find.textContaining('on the web'), findsOneWidget);
  });

  testWidgets('a load failure shows Retry, which refetches', (tester) async {
    final repo = FakeBoardsRepository(error: const ApiException('offline'));
    await pumpChoose(tester, repo);

    expect(find.byKey(const Key('choose_board_retry')), findsOneWidget);

    repo
      ..error = null
      ..boards = [makeBoard('alpha'), makeBoard('beta')];
    await tester.tap(find.byKey(const Key('choose_board_retry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('board_row_alpha')), findsOneWidget);
    expect(repo.calls, 2);
  });

  testWidgets('BoardRow marks the current board with ✓ and a primary border', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RelayTheme.light,
        home: Scaffold(
          body: BoardRow(
            board: makeBoard('alpha', name: 'Alpha', needsYou: 1),
            current: true,
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('board_row_current_alpha')), findsOneWidget);
    expect(find.text('1 needs you'), findsOneWidget);
    // No meta line unless asked (the sheet's rows omit it).
    expect(find.byKey(const Key('board_row_meta_alpha')), findsNothing);
    final material = tester.widget<Material>(
      find.byKey(const Key('board_row_surface_alpha')),
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.color, RelayTheme.light.colorScheme.primary);
    expect(shape.borderRadius, BorderRadius.circular(12));
  });
}
