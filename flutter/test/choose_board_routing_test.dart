import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:relay_mobile/main.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository;
import 'support/fake_auth.dart';
import 'support/fake_boards.dart';
import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';

const _signedIn = AuthState(
  status: AuthStatus.signedIn,
  user: {'email': 'd@acme.co'},
  token: 'relayu_t',
);

/// The real gated app (routerProvider + its redirect) — RE376 §3's launch rules.
Future<(ScriptedAuthController, ProviderContainer)> pumpGated(
  WidgetTester tester, {
  required InMemoryBoardPrefs prefs,
  required FakeBoardsRepository boards,
}) async {
  final auth = ScriptedAuthController();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        pushPlatformProvider.overrideWithValue(FakePushPlatform()),
        pushPrefsProvider.overrideWithValue(FakePushPrefs()),
        boardPrefsProvider.overrideWithValue(prefs),
        boardsRepositoryProvider.overrideWithValue(boards),
        feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
      ],
      child: const RelayApp(),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(RelayApp)),
  );
  return (auth, container);
}

void main() {
  testWidgets('a remembered board opens straight on Needs you', (tester) async {
    final (auth, _) = await pumpGated(
      tester,
      prefs: InMemoryBoardPrefs('alpha'),
      boards: FakeBoardsRepository(
        boards: [makeBoard('alpha'), makeBoard('beta')],
      ),
    );

    auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const Key('choose_board_title')), findsNothing);
  });

  testWidgets(
    'nothing remembered with several boards: Choose a board, and a pick lands on Needs you',
    (tester) async {
      final prefs = InMemoryBoardPrefs();
      final (auth, container) = await pumpGated(
        tester,
        prefs: prefs,
        boards: FakeBoardsRepository(
          boards: [
            makeBoard('alpha', name: 'Marketing site', needsYou: 2),
            makeBoard('beta', name: 'Data pipeline', needsYou: 1),
          ],
        ),
      );

      auth.resolve(_signedIn);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('choose_board_title')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.byKey(const Key('board_row_beta')));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(container.read(currentBoardProvider).slug, 'beta');
      expect(prefs.slug, 'beta');
    },
  );

  testWidgets('a one-board user skips Choose a board', (tester) async {
    final prefs = InMemoryBoardPrefs();
    final (auth, _) = await pumpGated(
      tester,
      prefs: prefs,
      boards: FakeBoardsRepository(boards: [makeBoard('only')]),
    );

    auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const Key('choose_board_title')), findsNothing);
    expect(prefs.slug, 'only');
  });

  testWidgets(
    'a remembered board that is gone sends the user to Choose a board',
    (tester) async {
      final prefs = InMemoryBoardPrefs('gone');
      final (auth, _) = await pumpGated(
        tester,
        prefs: prefs,
        boards: FakeBoardsRepository(
          boards: [makeBoard('alpha'), makeBoard('beta')],
        ),
      );

      auth.resolve(_signedIn);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('choose_board_title')), findsOneWidget);
      expect(prefs.slug, isNull);
    },
  );
}
