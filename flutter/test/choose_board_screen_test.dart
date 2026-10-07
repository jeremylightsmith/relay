import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/board_summary.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/choose_board_screen.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/boards/widgets/board_row.dart';

import 'support/fake_boards.dart';

Future<void> pumpRow(
  WidgetTester tester,
  BoardSummary board, {
  bool current = false,
  VoidCallback? onTap,
  VoidCallback? onToggleStar,
  VoidCallback? onToggleMute,
}) => tester.pumpWidget(
  MaterialApp(
    theme: RelayTheme.light,
    home: Scaffold(
      body: BoardRow(
        board: board,
        current: current,
        onTap: onTap ?? () {},
        onToggleStar: onToggleStar ?? () {},
        onToggleMute: onToggleMute ?? () {},
      ),
    ),
  ),
);

Icon starIcon(WidgetTester tester, String slug) => tester.widget<Icon>(
  find.descendant(
    of: find.byKey(Key('board_row_star_$slug')),
    matching: find.byType(Icon),
  ),
);

Icon muteIcon(WidgetTester tester, String slug) => tester.widget<Icon>(
  find.descendant(
    of: find.byKey(Key('board_row_mute_$slug')),
    matching: find.byType(Icon),
  ),
);

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

    // Row: rounded-xl border-base-300 py-1 pl-3 pr-1 (RE396) → radius 12,
    // outlineVariant, padding 12/4/4/4.
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
    expect(padding.padding, const EdgeInsets.fromLTRB(12, 4, 4, 4));

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
            onToggleStar: () {},
            onToggleMute: () {},
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

  // Card mockup "B — native Switch board sheet: same order, star at far right
  // of each row" (RE396).
  group('BoardRow star', () {
    testWidgets('starred: solid star in onSurface, size 20, "Unstar board"', (
      tester,
    ) async {
      await pumpRow(tester, makeBoard('alpha', starred: true));

      final icon = starIcon(tester, 'alpha');
      expect(icon.icon, Icons.star);
      expect(icon.color, RelayTheme.light.colorScheme.onSurface);
      expect(icon.size, 20);
      expect(find.bySemanticsLabel('Unstar board'), findsOneWidget);
    });

    testWidgets('unstarred: outline star in onSurface/40, "Star board"', (
      tester,
    ) async {
      await pumpRow(tester, makeBoard('alpha'));

      final scheme = RelayTheme.light.colorScheme;
      final icon = starIcon(tester, 'alpha');
      expect(icon.icon, Icons.star_border);
      expect(icon.color, scheme.onSurface.withValues(alpha: 0.4));
      expect(icon.size, 20);
      expect(find.bySemanticsLabel('Star board'), findsOneWidget);
      // Neutral — never brand-colored, never amber.
      expect(icon.color, isNot(scheme.primary));
      expect(icon.color, isNot(scheme.secondary));
      expect(icon.color, isNot(RelayTheme.relayNeedsInputText));
    });

    testWidgets('tapping the star toggles it without switching boards', (
      tester,
    ) async {
      var taps = 0;
      var stars = 0;
      await pumpRow(
        tester,
        makeBoard('alpha'),
        onTap: () => taps++,
        onToggleStar: () => stars++,
      );

      await tester.tap(find.byKey(const Key('board_row_star_alpha')));
      await tester.pumpAndSettle();
      expect(stars, 1);
      expect(taps, 0);

      await tester.tap(find.text('alpha'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(stars, 1);
    });

    testWidgets('order: badge, ✓, then the star at the far right', (
      tester,
    ) async {
      await pumpRow(tester, makeBoard('alpha', needsYou: 2), current: true);

      final star = tester.getRect(
        find.byKey(const Key('board_row_star_alpha')),
      );
      final check = tester.getRect(
        find.byKey(const Key('board_row_current_alpha')),
      );
      final badge = tester.getRect(
        find.byKey(const Key('board_row_needs_you_alpha')),
      );
      final surface = tester.getRect(
        find.byKey(const Key('board_row_surface_alpha')),
      );
      expect(star.left, greaterThanOrEqualTo(check.right));
      expect(check.left, greaterThanOrEqualTo(badge.right));
      expect((surface.right - star.right).abs(), lessThanOrEqualTo(4));
    });

    testWidgets('the star is at least a 44×44 tap target', (tester) async {
      await pumpRow(tester, makeBoard('alpha'));

      final size = tester.getSize(
        find.byKey(const Key('board_row_star_alpha')),
      );
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });
  });

  testWidgets('Choose a board: the star stars without choosing (RE396)', (
    tester,
  ) async {
    final repo = FakeBoardsRepository(
      boards: [makeBoard('alpha'), makeBoard('beta')],
    );
    await pumpChoose(tester, repo);

    expect(find.byKey(const Key('board_row_star_alpha')), findsOneWidget);
    expect(find.byKey(const Key('board_row_star_beta')), findsOneWidget);

    await tester.tap(find.byKey(const Key('board_row_star_beta')));
    await tester.pumpAndSettle();

    expect(repo.starCalls, [('beta', true)]);
    expect(find.byKey(const Key('choose_board_title')), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChooseBoardScreen)),
    );
    expect(container.read(currentBoardProvider).slug, isNot('beta'));
  });

  // Card mockup "A — bell beside the star on the shared board row (Choose a
  // board + Switch board sheet)" (RE406).
  group('BoardRow bell (RE406)', () {
    testWidgets(
      'notifying: outline bell in onSurface/40, "Mute notifications"',
      (tester) async {
        await pumpRow(tester, makeBoard('alpha'));

        final icon = muteIcon(tester, 'alpha');
        expect(icon.icon, Icons.notifications_none);
        expect(icon.size, 20);
        expect(
          icon.color,
          RelayTheme.light.colorScheme.onSurface.withValues(alpha: 0.4),
        );
        expect(find.bySemanticsLabel('Mute notifications'), findsOneWidget);
      },
    );

    testWidgets('muted: slashed bell in onSurface/40, "Unmute notifications"', (
      tester,
    ) async {
      await pumpRow(tester, makeBoard('alpha', muted: true));

      final scheme = RelayTheme.light.colorScheme;
      final icon = muteIcon(tester, 'alpha');
      expect(icon.icon, Icons.notifications_off_outlined);
      expect(icon.size, 20);
      expect(icon.color, scheme.onSurface.withValues(alpha: 0.4));
      expect(icon.color, isNot(scheme.primary));
      expect(icon.color, isNot(scheme.secondary));
      expect(find.bySemanticsLabel('Unmute notifications'), findsOneWidget);
    });

    testWidgets('order: ✓, then the bell, then the star at the far right', (
      tester,
    ) async {
      await pumpRow(tester, makeBoard('alpha', needsYou: 2), current: true);

      final check = tester.getRect(
        find.byKey(const Key('board_row_current_alpha')),
      );
      final bell = tester.getRect(
        find.byKey(const Key('board_row_mute_alpha')),
      );
      final star = tester.getRect(
        find.byKey(const Key('board_row_star_alpha')),
      );
      final surface = tester.getRect(
        find.byKey(const Key('board_row_surface_alpha')),
      );
      expect(bell.left, greaterThanOrEqualTo(check.right));
      expect(star.left, greaterThanOrEqualTo(bell.right));
      expect((surface.right - star.right).abs(), lessThanOrEqualTo(4));
    });

    testWidgets('tapping the bell only toggles the mute', (tester) async {
      var taps = 0;
      var stars = 0;
      var mutes = 0;
      await pumpRow(
        tester,
        makeBoard('alpha'),
        onTap: () => taps++,
        onToggleStar: () => stars++,
        onToggleMute: () => mutes++,
      );

      await tester.tap(find.byKey(const Key('board_row_mute_alpha')));
      await tester.pumpAndSettle();

      expect(mutes, 1);
      expect(taps, 0);
      expect(stars, 0);
    });

    testWidgets('the bell is at least a 44×44 tap target', (tester) async {
      await pumpRow(tester, makeBoard('alpha'));

      final size = tester.getSize(
        find.byKey(const Key('board_row_mute_alpha')),
      );
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('a muted row is not dimmed and keeps its needs-you badge', (
      tester,
    ) async {
      await pumpRow(tester, makeBoard('alpha', muted: true, needsYou: 1));

      final material = tester.widget<Material>(
        find.byKey(const Key('board_row_surface_alpha')),
      );
      expect(material.color, RelayTheme.light.colorScheme.surface);
      expect(find.text('1 needs you'), findsOneWidget);
    });
  });

  testWidgets('Choose a board: the bell mutes without choosing (RE406)', (
    tester,
  ) async {
    final repo = FakeBoardsRepository(
      boards: [makeBoard('alpha'), makeBoard('beta')],
    );
    await pumpChoose(tester, repo);

    await tester.tap(find.byKey(const Key('board_row_mute_beta')));
    await tester.pumpAndSettle();

    expect(repo.muteCalls, [('beta', true)]);
    expect(find.byKey(const Key('choose_board_title')), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChooseBoardScreen)),
    );
    expect(container.read(currentBoardProvider).slug, isNot('beta'));
    expect(
      tester.getTopLeft(find.byKey(const Key('board_row_alpha'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('board_row_beta'))).dy),
    );
    expect(find.byType(SnackBar), findsNothing);
  });
}
