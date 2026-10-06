import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:relay_mobile/main.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;
import 'support/fake_auth.dart';
import 'support/fake_boards.dart';
import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';
import 'support/stub_adapter.dart';

const _signedIn = AuthState(
  status: AuthStatus.signedIn,
  user: {'email': 'd@acme.co'},
  token: 'relayu_t',
);

const _datPush = {
  'card_ref': 'DAT-12',
  'board_slug': 'dat',
  'kind': 'needs_input',
};

const _mktPush = {
  'card_ref': 'MKT-1',
  'board_slug': 'mkt',
  'kind': 'in_review',
};

/// The real gated app with a two-board user (RE376 · PUSH-01).
Future<(ScriptedAuthController, FakePushPlatform, ProviderContainer)>
pumpLaunch(
  WidgetTester tester, {
  required InMemoryBoardPrefs prefs,
  Map<String, dynamic>? coldNotification,
}) async {
  final auth = ScriptedAuthController();
  final platform = FakePushPlatform()..initial = coldNotification;
  // The card screen's summary fetch (RLY-98): any 404 degrades to "no chip".
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  )..httpClientAdapter = StubAdapter(statusCode: 404);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        pushPlatformProvider.overrideWithValue(platform),
        pushPrefsProvider.overrideWithValue(FakePushPrefs()),
        boardPrefsProvider.overrideWithValue(prefs),
        boardsRepositoryProvider.overrideWithValue(
          FakeBoardsRepository(
            boards: [
              makeBoard('mkt', name: 'Marketing site', needsYou: 1),
              makeBoard('dat', name: 'Data pipeline', needsYou: 1),
            ],
          ),
        ),
        feedRepositoryProvider.overrideWithValue(
          FakeFeedRepository(
            page: FeedPage(
              rows: [
                makeRow(ref: 'MKT-1', boardKey: 'MKT'),
                makeRow(ref: 'DAT-12', boardKey: 'DAT', kind: 'needs_input'),
              ],
              meta: const FeedMeta(count: 2),
            ),
          ),
        ),
        apiClientProvider.overrideWithValue(
          ApiClient(tokenReader: () => 'relayu_t', dio: dio),
        ),
        cardBodyBuilderProvider.overrideWithValue(
          (_) => const SizedBox.shrink(key: Key('stub_card_body')),
        ),
      ],
      child: const RelayApp(),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(RelayApp)),
  );
  return (auth, platform, container);
}

void main() {
  testWidgets(
    'a push for another board switches the app, toasts, opens the card — and back '
    'lands on that board\'s Needs you',
    (tester) async {
      final (auth, platform, container) = await pumpLaunch(
        tester,
        prefs: InMemoryBoardPrefs('mkt'),
      );
      auth.resolve(_signedIn);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);

      platform.tapHandler!(_datPush);
      await tester.pumpAndSettle();

      expect(
        tester.widget<CardScreen>(find.byType(CardScreen)).cardRef,
        'DAT-12',
      );
      expect(container.read(currentBoardProvider).slug, 'dat');
      expect(find.byKey(const Key('board_switched_toast')), findsOneWidget);
      expect(find.text('Switched to Data pipeline'), findsOneWidget);

      expect(
        tester.widget<CardScreen>(find.byType(CardScreen)).backLabel,
        isNull,
        reason: 'a push is an orphan — the web shows plain "Back"',
      );

      CardScreen.navBack(GoRouter.of(tester.element(find.byType(CardScreen))));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs_you_header')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('board_switcher_name'))).data,
        'Data pipeline',
      );
      expect(find.byKey(const Key('inbox_row_DAT-12')), findsOneWidget);
      expect(find.byKey(const Key('inbox_row_MKT-1')), findsNothing);
    },
  );

  testWidgets('a push for the current board neither switches nor toasts', (
    tester,
  ) async {
    final (auth, platform, container) = await pumpLaunch(
      tester,
      prefs: InMemoryBoardPrefs('mkt'),
    );
    auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    platform.tapHandler!(_mktPush);
    await tester.pumpAndSettle();

    expect(tester.widget<CardScreen>(find.byType(CardScreen)).cardRef, 'MKT-1');
    expect(container.read(currentBoardProvider).slug, 'mkt');
    expect(find.byKey(const Key('board_switched_toast')), findsNothing);
  });

  testWidgets('a cold-start push for another board lands on its card', (
    tester,
  ) async {
    final (auth, _, container) = await pumpLaunch(
      tester,
      prefs: InMemoryBoardPrefs('mkt'),
      coldNotification: _datPush,
    );
    await tester.pump();

    auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(
      tester.widget<CardScreen>(find.byType(CardScreen)).cardRef,
      'DAT-12',
    );
    expect(container.read(currentBoardProvider).slug, 'dat');
  });

  testWidgets(
    'a cold-start push with no remembered board never shows Choose a board',
    (tester) async {
      final (auth, _, container) = await pumpLaunch(
        tester,
        prefs: InMemoryBoardPrefs(),
        coldNotification: _datPush,
      );
      await tester.pump();

      auth.resolve(_signedIn);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('choose_board_title')), findsNothing);
      expect(
        tester.widget<CardScreen>(find.byType(CardScreen)).cardRef,
        'DAT-12',
      );
      expect(container.read(currentBoardProvider).slug, 'dat');
    },
  );
}
