import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/tabs.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/board/last_place.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/push/push_prefs.dart';
import 'package:relay_mobile/features/push/push_service.dart';
import 'package:relay_mobile/main.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository;
import 'support/fake_auth.dart';
import 'support/fake_boards.dart';
import 'support/fake_push_platform.dart';
import 'support/fake_push_prefs.dart';

/// Counts writes, so "no write" is asserted directly rather than inferred.
class _CountingStore extends InMemoryLastPlaceStore {
  _CountingStore([super.place]);

  int writes = 0;

  @override
  Future<void> write(LastPlace place) {
    writes++;
    return super.write(place);
  }
}

Future<(LastPlaceTracker, ProviderContainer)> trackerOver(
  LastPlaceStore store,
) async {
  final c = ProviderContainer(
    overrides: [lastPlaceStoreProvider.overrideWithValue(store)],
  );
  addTearDown(c.dispose);
  final controller = c.read(lastPlaceProvider.notifier);
  await controller.ready;
  return (LastPlaceTracker(controller), c);
}

void main() {
  test('a tab root records that tab, query and all', () async {
    final (tracker, c) = await trackerOver(InMemoryLastPlaceStore());
    LastPlace? place() => c.read(lastPlaceProvider).place;

    tracker.onLocation(Uri.parse('/board?stage=12'));
    await pumpEventQueue();
    expect(place()!.tab, AppTab.board);
    expect(place()!.cardRef, isNull);

    tracker.onLocation(Uri.parse('/needs-you'));
    await pumpEventQueue();
    expect(place()!.tab, AppTab.needsYou);

    tracker.onLocation(Uri.parse('/settings'));
    await pumpEventQueue();
    expect(place()!.tab, AppTab.settings);
  });

  test('a card opened from the Board tab is remembered, and the ‹ › nav '
      'follows it', () async {
    final (tracker, c) = await trackerOver(InMemoryLastPlaceStore());
    LastPlace? place() => c.read(lastPlaceProvider).place;

    tracker.onLocation(
      Uri.parse('/cards/RE440?board=relay&kind=in_review&back=Board'),
    );
    await pumpEventQueue();
    expect(place(), const LastPlace(tab: AppTab.board, cardRef: 'RE440'));

    tracker.onLocation(Uri.parse('/cards/RE441?board=relay&back=Board'));
    await pumpEventQueue();
    expect(place()!.cardRef, 'RE441');
  });

  test('cards not opened from Board, and scaffolding routes, write '
      'nothing', () async {
    final store = _CountingStore(const LastPlace(tab: AppTab.needsYou));
    final (tracker, c) = await trackerOver(store);

    for (final loc in [
      '/cards/RE7?board=relay',
      '/cards/RE7?board=relay&back=Needs%20you',
      '/card/RE7/reject?board=relay',
      '/choose-board',
      '/splash',
      '/welcome/sign-in',
      '/push-permission',
    ]) {
      tracker.onLocation(Uri.parse(loc));
    }
    await pumpEventQueue();

    expect(
      c.read(lastPlaceProvider).place,
      const LastPlace(tab: AppTab.needsYou),
    );
    expect(store.writes, 0);
  });

  test('the same location twice in a row writes once', () async {
    final store = _CountingStore();
    final (tracker, _) = await trackerOver(store);

    tracker.onLocation(Uri.parse('/settings'));
    tracker.onLocation(Uri.parse('/settings'));
    await pumpEventQueue();

    expect(store.writes, 1);
  });

  testWidgets('the production router records navigation through its '
      'delegate', (tester) async {
    final store = InMemoryLastPlaceStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(
            () => FakeAuthController(
              const AuthState(
                status: AuthStatus.signedIn,
                user: {'email': 'd@acme.co'},
                token: 'relayu_t',
              ),
            ),
          ),
          pushPlatformProvider.overrideWithValue(FakePushPlatform()),
          pushPrefsProvider.overrideWithValue(FakePushPrefs()),
          boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('relay')),
          boardsRepositoryProvider.overrideWithValue(
            FakeBoardsRepository(boards: [makeBoard('relay')]),
          ),
          feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
          lastPlaceStoreProvider.overrideWithValue(store),
          boardBodyBuilderProvider.overrideWithValue(
            (_) => const SizedBox.shrink(key: Key('stub_board_body')),
          ),
          cardBodyBuilderProvider.overrideWithValue(
            (_) => const SizedBox.shrink(key: Key('stub_card_body')),
          ),
        ],
        child: const RelayApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RelayApp)),
    );

    final router = container.read(routerProvider);
    router.go('/settings');
    await tester.pumpAndSettle();

    expect(store.place?.tab, AppTab.settings);

    // A card is opened from the Board tab with a push (BoardScreen's
    // relayCardTap), which leaves the router's base uri on /board — the
    // tracker has to read the pushed top match, not the base uri.
    router.go('/board');
    await tester.pumpAndSettle();
    expect(store.place, const LastPlace(tab: AppTab.board));

    unawaited(router.push('/cards/RE440?board=relay&back=Board'));
    await tester.pumpAndSettle();
    expect(store.place, const LastPlace(tab: AppTab.board, cardRef: 'RE440'));

    // ‹ Board pops back to the base /board — same uri as before the push, so
    // the dedupe must not swallow it: the card is cleared.
    router.pop();
    await tester.pumpAndSettle();
    expect(store.place, const LastPlace(tab: AppTab.board));
  });
}
