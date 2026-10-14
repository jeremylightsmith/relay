import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/launch_restorer.dart';
import 'package:relay_mobile/app/messenger.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/tabs.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/board/board_screen.dart';
import 'package:relay_mobile/features/board/last_place.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';
import 'package:relay_mobile/features/needs_you/needs_you_screen.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:relay_mobile/main.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;
import 'support/fake_auth.dart';
import 'support/fake_boards.dart';
import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';
import 'support/hanging_adapter.dart';
import 'support/stub_adapter.dart';

const _signedIn = AuthState(
  status: AuthStatus.signedIn,
  user: {'email': 'd@acme.co'},
  token: 'relayu_t',
);

/// The remembered Board-tab card most scenarios restore.
const _specCard = LastPlace(
  tab: AppTab.board,
  stageId: 20,
  stageName: 'Spec',
  cardRef: 'RE440',
);

Map<String, dynamic> _cardBody({
  bool archived = false,
  int stageId = 20,
  String status = 'in_review',
}) => {
  'data': {
    'ref': 'RE440',
    'archived': archived,
    'stage_id': stageId,
    'status': status,
  },
};

/// One gated launch (RE452): the real `RelayApp` + routerProvider redirect, with
/// auth scripted, the webview bodies stubbed and the card API behind [adapter].
class _Launch {
  _Launch(this.auth, this.platform, this.container, this.store);

  final ScriptedAuthController auth;
  final FakePushPlatform platform;
  final ProviderContainer container;
  final InMemoryLastPlaceStore store;

  Uri get location =>
      container.read(routerProvider).routerDelegate.currentConfiguration.uri;
}

Future<_Launch> _pumpLaunch(
  WidgetTester tester, {
  LastPlace? place,
  InMemoryBoardPrefs? prefs,
  HttpClientAdapter? adapter,
  Map<String, dynamic>? coldNotification,
}) async {
  final auth = ScriptedAuthController();
  final platform = FakePushPlatform()..initial = coldNotification;
  final store = InMemoryLastPlaceStore(place);
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  )..httpClientAdapter = adapter ?? StubAdapter(statusCode: 404);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        pushPlatformProvider.overrideWithValue(platform),
        pushPrefsProvider.overrideWithValue(FakePushPrefs()),
        boardPrefsProvider.overrideWithValue(
          prefs ?? InMemoryBoardPrefs('relay'),
        ),
        lastPlaceStoreProvider.overrideWithValue(store),
        boardsRepositoryProvider.overrideWithValue(
          FakeBoardsRepository(
            boards: [
              makeBoard('relay', name: 'Relay'),
              makeBoard('mkt', name: 'Marketing site'),
            ],
          ),
        ),
        feedRepositoryProvider.overrideWithValue(
          FakeFeedRepository(
            page: FeedPage(
              rows: [makeRow(ref: 'RE1', boardKey: 'RE')],
              meta: const FeedMeta(count: 1),
            ),
          ),
        ),
        apiClientProvider.overrideWithValue(
          ApiClient(tokenReader: () => 'relayu_t', dio: dio),
        ),
        cardBodyBuilderProvider.overrideWithValue(
          (_) => const SizedBox.shrink(key: Key('stub_card_body')),
        ),
        boardBodyBuilderProvider.overrideWithValue(
          (_) => const SizedBox.shrink(key: Key('stub_board_body')),
        ),
      ],
      child: const RelayApp(),
    ),
  );
  // pump(), not pumpAndSettle(): the splash's progress indicator never settles.
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(RelayApp)),
  );
  return _Launch(auth, platform, container, store);
}

Finder _cardFor(String ref) =>
    find.byWidgetPredicate((w) => w is CardScreen && w.cardRef == ref);

bool _sawCard(List<RequestOptions> requests, String ref) => requests.any(
  (r) =>
      r.uri.path == '/api/all/cards/$ref' &&
      r.uri.queryParameters['board'] == 'relay',
);

/// The board screen's element doubles as the WidgetRef its JS handlers get.
WidgetRef _boardRef(WidgetTester tester) =>
    tester.element(find.byType(BoardScreen)) as WidgetRef;

void _dismissToasts(_Launch launch) => launch.container
    .read(scaffoldMessengerKeyProvider)
    .currentState!
    .removeCurrentSnackBar();

void main() {
  testWidgets('1 · nothing remembered lands on Needs you', (tester) async {
    final launch = await _pumpLaunch(tester);

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/needs-you');
  });

  testWidgets('2 · a remembered Settings tab reopens Settings, never showing '
      'Needs you first', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: const LastPlace(tab: AppTab.settings),
    );

    launch.auth.resolve(_signedIn);
    for (var i = 0; i < 30 && launch.location.path != '/settings'; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byType(NeedsYouScreen),
        findsNothing,
        reason: 'the splash holds until the place is read — no inbox flash',
      );
    }
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/settings');
    expect(find.byType(NeedsYouScreen), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('3 · a remembered stage page reopens the Board tab on it', (
    tester,
  ) async {
    final launch = await _pumpLaunch(
      tester,
      place: const LastPlace(tab: AppTab.board, stageId: 30, stageName: 'Code'),
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/board?stage=30');
    expect(tester.widget<BoardScreen>(find.byType(BoardScreen)).stageId, 30);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('4 · a live Board-tab card reopens silently over its stage', (
    tester,
  ) async {
    final adapter = StubAdapter(body: _cardBody());
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: adapter,
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    final card = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(card.cardRef, 'RE440');
    expect(card.kind, 'in_review');
    expect(card.backLabel, 'Board');
    expect(find.byType(SnackBar), findsNothing);
    expect(_sawCard(adapter.requests, 'RE440'), isTrue);

    CardScreen.navBack(launch.container.read(routerProvider));
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/board?stage=20');
  });

  testWidgets('5 · a card that moved reopens silently, and ‹ Board goes to its '
      'current stage', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: StubAdapter(body: _cardBody(stageId: 30)),
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(tester.widget<CardScreen>(find.byType(CardScreen)).cardRef, 'RE440');
    expect(find.byType(SnackBar), findsNothing);

    CardScreen.navBack(launch.container.read(routerProvider));
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/board?stage=30');
  });

  testWidgets('6 · an archived card falls back to its stage with a toast', (
    tester,
  ) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: StubAdapter(body: _cardBody(archived: true)),
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/board?stage=20');
    expect(find.byType(CardScreen), findsNothing);
    expect(find.byKey(LaunchRestorer.toastKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(LaunchRestorer.toastKey),
        matching: find.text('RE440 was archived'),
      ),
      findsOneWidget,
    );
    expect(launch.store.place?.cardRef, isNull);
  });

  testWidgets('7 · a deleted card falls back to the remembered stage with a '
      'toast', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: StubAdapter(statusCode: 404),
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/board?stage=20');
    expect(find.byType(CardScreen), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(LaunchRestorer.toastKey),
        matching: find.text('RE440 was deleted'),
      ),
      findsOneWidget,
    );
    expect(launch.store.place?.cardRef, isNull);
  });

  testWidgets('8 · offline: after the verify timeout the card opens over the '
      'remembered stage with no kind and no toast', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: HangingAdapter(),
    );

    launch.auth.resolve(_signedIn);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CardScreen), findsNothing);

    await tester.pump(LaunchRestorer.verifyTimeout);
    await tester.pumpAndSettle();

    final card = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(card.cardRef, 'RE440');
    expect(card.kind, isNull);
    expect(find.byType(SnackBar), findsNothing);

    CardScreen.navBack(launch.container.read(routerProvider));
    await tester.pumpAndSettle();
    expect(launch.location.toString(), '/board?stage=20');
  });

  testWidgets('8 · a body it cannot read opens the card unverified, like '
      'offline', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: StubAdapter(body: const {'data': 'nope'}),
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    final card = tester.widget<CardScreen>(find.byType(CardScreen));
    expect(card.cardRef, 'RE440');
    expect(card.kind, isNull);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('9 · a cold push tap beats the remembered card', (tester) async {
    final adapter = StubAdapter(body: _cardBody());
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: adapter,
      coldNotification: const {
        'card_ref': 'RE7',
        'board_slug': 'relay',
        'kind': 'needs_input',
      },
    );
    await tester.pump();

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(tester.widget<CardScreen>(find.byType(CardScreen)).cardRef, 'RE7');
    expect(_sawCard(adapter.requests, 'RE440'), isFalse);
  });

  testWidgets(
    '10 · a warm push tap mid-verify wins, and the restore abandons',
    (tester) async {
      final launch = await _pumpLaunch(
        tester,
        place: _specCard,
        adapter: HangingAdapter(),
      );

      launch.auth.resolve(_signedIn);
      await tester.pump();
      await tester.pump();
      expect(launch.container.read(launchRestorerProvider).resolving, isTrue);

      launch.platform.tapHandler!(const {
        'card_ref': 'RE7',
        'board_slug': 'relay',
        'kind': 'needs_input',
      });
      await tester.pumpAndSettle();
      await tester.pump(LaunchRestorer.verifyTimeout);
      await tester.pumpAndSettle();

      expect(tester.widget<CardScreen>(find.byType(CardScreen)).cardRef, 'RE7');
      expect(_cardFor('RE440'), findsNothing);
      expect(launch.location.path, '/cards/RE7');
    },
  );

  testWidgets('11 · an interactive sign-in primes push permission, never the '
      'remembered card', (tester) async {
    final adapter = StubAdapter(body: _cardBody());
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: adapter,
    );

    launch.auth.resolve(const AuthState(status: AuthStatus.signedOut));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('welcome_screen')), findsOneWidget);

    await launch.auth.signInWithGoogle();
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/push-permission');
    expect(_cardFor('RE440'), findsNothing);
    expect(_sawCard(adapter.requests, 'RE440'), isFalse);
  });

  testWidgets('12 · no board: Choose a board, whatever was remembered', (
    tester,
  ) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      prefs: InMemoryBoardPrefs(),
      adapter: StubAdapter(body: _cardBody()),
    );

    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    expect(launch.location.toString(), '/choose-board');
  });

  testWidgets('13 · a missing restored stage toasts once', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: const LastPlace(tab: AppTab.board, stageId: 20, stageName: 'Spec'),
    );
    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();
    expect(launch.location.toString(), '/board?stage=20');

    BoardScreen.onStageMissing(_boardRef(tester), {'stage_id': 20});
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(LaunchRestorer.toastKey),
        matching: find.text('The Spec stage no longer exists'),
      ),
      findsOneWidget,
    );

    _dismissToasts(launch);
    await tester.pumpAndSettle();
    BoardScreen.onStageMissing(_boardRef(tester), {'stage_id': 20});
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('14 · card and stage both gone: only the card\'s toast', (
    tester,
  ) async {
    final launch = await _pumpLaunch(
      tester,
      place: _specCard,
      adapter: StubAdapter(body: _cardBody(archived: true)),
    );
    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();
    expect(find.text('RE440 was archived'), findsOneWidget);

    _dismissToasts(launch);
    await tester.pumpAndSettle();
    BoardScreen.onStageMissing(_boardRef(tester), {'stage_id': 20});
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('The Spec stage no longer exists'), findsNothing);
  });

  testWidgets('15 · an in-session ?stage= never toasts', (tester) async {
    final launch = await _pumpLaunch(tester);
    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    launch.container.read(routerProvider).go('/board?stage=20');
    await tester.pumpAndSettle();
    BoardScreen.onStageMissing(_boardRef(tester), {'stage_id': 20});
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('15 · a stage-missing for another stage than the restored one '
      'never toasts', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: const LastPlace(tab: AppTab.board, stageId: 20, stageName: 'Spec'),
    );
    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();

    BoardScreen.onStageMissing(_boardRef(tester), {'stage_id': 99});
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('15 · a board switch after a stage restore drops the stage and '
      'never toasts about it', (tester) async {
    final launch = await _pumpLaunch(
      tester,
      place: const LastPlace(tab: AppTab.board, stageId: 20, stageName: 'Spec'),
    );
    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();
    expect(launch.location.toString(), '/board?stage=20');

    // The Board tab's switcher: switchTo only, no navigation of its own.
    await launch.container.read(currentBoardProvider.notifier).switchTo('mkt');
    await tester.pumpAndSettle();

    // Stage ids are global: the old board's stage must not ride onto this one.
    expect(launch.location.toString(), '/board');
    expect(
      tester.widget<BoardScreen>(find.byType(BoardScreen)).stageId,
      isNull,
    );

    // Even if the new board's pager reports the old id missing, no toast.
    BoardScreen.onStageMissing(_boardRef(tester), {'stage_id': 20});
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('16 · the push board-switch toast still shows through the shared '
      'helper', (tester) async {
    final launch = await _pumpLaunch(tester);
    launch.auth.resolve(_signedIn);
    await tester.pumpAndSettle();
    expect(launch.location.toString(), '/needs-you');

    launch.platform.tapHandler!(const {
      'card_ref': 'MKT-1',
      'board_slug': 'mkt',
      'kind': 'in_review',
    });
    await tester.pumpAndSettle();

    final toast = tester.widget<SnackBar>(
      find.byKey(const Key('board_switched_toast')),
    );
    expect((toast.content as Text).data, 'Switched to Marketing site');
    expect(toast.duration, toastDuration);
  });

  test('boardLocation names the stage page, or the first one', () {
    expect(LaunchRestorer.boardLocation(null), '/board');
    expect(LaunchRestorer.boardLocation(30), '/board?stage=30');
  });
}
