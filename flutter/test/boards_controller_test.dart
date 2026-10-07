import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/board_summary.dart';
import 'package:relay_mobile/features/boards/boards_controller.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/needs_you/feed_controller.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;
import 'support/fake_boards.dart';

ProviderContainer containerWith({
  required FakeBoardsRepository repo,
  InMemoryBoardPrefs? prefs,
  String? token = 'relayu_t',
  FakeFeedRepository? feed,
}) {
  final c = ProviderContainer(
    overrides: [
      boardsRepositoryProvider.overrideWithValue(repo),
      boardPrefsProvider.overrideWithValue(prefs ?? InMemoryBoardPrefs()),
      authTokenProvider.overrideWithValue(token),
      feedRepositoryProvider.overrideWithValue(feed ?? FakeFeedRepository()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test(
    'loads the boards and keeps a remembered board that is listed',
    () async {
      final c = containerWith(
        repo: FakeBoardsRepository(
          boards: [makeBoard('alpha'), makeBoard('beta')],
        ),
        prefs: InMemoryBoardPrefs('alpha'),
      );

      final boards = await c.read(boardsProvider.future);

      expect(boards.map((b) => b.slug), ['alpha', 'beta']);
      expect(c.read(currentBoardProvider).slug, 'alpha');
    },
  );

  test('a remembered board that is gone is cleared after a load', () async {
    final prefs = InMemoryBoardPrefs('gone');
    final c = containerWith(
      repo: FakeBoardsRepository(
        boards: [makeBoard('alpha'), makeBoard('beta')],
      ),
      prefs: prefs,
    );

    await c.read(boardsProvider.future);

    expect(c.read(currentBoardProvider).needsChoice, isTrue);
    expect(prefs.slug, isNull);
  });

  test('a single board is auto-selected when nothing is remembered', () async {
    final prefs = InMemoryBoardPrefs();
    final c = containerWith(
      repo: FakeBoardsRepository(boards: [makeBoard('only')]),
      prefs: prefs,
    );

    await c.read(boardsProvider.future);

    expect(c.read(currentBoardProvider).slug, 'only');
    expect(prefs.slug, 'only');
  });

  test('no token: MissingTokenException and no request', () async {
    final repo = FakeBoardsRepository(boards: [makeBoard('alpha')]);
    final c = containerWith(repo: repo, token: null);

    await expectLater(
      c.read(boardsProvider.future),
      throwsA(isA<MissingTokenException>()),
    );
    expect(repo.calls, 0);
  });

  test('refresh refetches the list', () async {
    final repo = FakeBoardsRepository(boards: [makeBoard('alpha')]);
    final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
    await c.read(boardsProvider.future);

    await c.read(boardsProvider.notifier).refresh();

    expect(repo.calls, 2);
  });

  group('currentBoardNameProvider', () {
    test('names the current board from the list', () async {
      final c = containerWith(
        repo: FakeBoardsRepository(
          boards: [makeBoard('alpha', name: 'Marketing site')],
        ),
        prefs: InMemoryBoardPrefs('alpha'),
      );
      await c.read(boardsProvider.future);

      expect(c.read(currentBoardNameProvider), 'Marketing site');
    });

    test(
      'falls back to a feed row\'s board name when the list failed',
      () async {
        final c = containerWith(
          repo: FakeBoardsRepository(error: const ApiException('offline')),
          prefs: InMemoryBoardPrefs('alpha'),
          feed: FakeFeedRepository(
            page: FeedPage(
              rows: [makeRow(ref: 'ALPHA-1', boardKey: 'ALPHA')],
              meta: const FeedMeta(count: 1),
            ),
          ),
        );
        await c.read(currentBoardProvider.notifier).ready;
        await c.read(feedControllerProvider.future);
        await expectLater(c.read(boardsProvider.future), throwsA(anything));

        // makeRow's board is {name: 'Relay', slug: boardKey.toLowerCase()}.
        expect(c.read(currentBoardNameProvider), 'Relay');
      },
    );

    test('is null when nothing knows the board yet', () async {
      final c = containerWith(
        repo: FakeBoardsRepository(error: const ApiException('offline')),
        prefs: InMemoryBoardPrefs('alpha'),
      );
      await c.read(currentBoardProvider.notifier).ready;

      expect(c.read(currentBoardNameProvider), isNull);
    });
  });

  group('toggleStar (RE396)', () {
    List<String> slugs(ProviderContainer c) =>
        c.read(boardsProvider).value!.map((b) => b.slug).toList();
    List<bool> stars(ProviderContainer c) =>
        c.read(boardsProvider).value!.map((b) => b.starred).toList();

    test('stars an unstarred board, then renders the server order', () async {
      final repo =
          FakeBoardsRepository(boards: [makeBoard('alpha'), makeBoard('beta')])
            ..onStar = (r) => r.boards = [
              makeBoard('beta', starred: true),
              makeBoard('alpha'),
            ];
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);

      await c.read(boardsProvider.notifier).toggleStar('beta');

      expect(repo.starCalls, [('beta', true)]);
      expect(repo.calls, 2);
      expect(slugs(c), ['beta', 'alpha']);
      expect(stars(c), [true, false]);
    });

    test('unstars a starred board', () async {
      final repo = FakeBoardsRepository(
        boards: [makeBoard('alpha', starred: true)],
      );
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);

      await c.read(boardsProvider.notifier).toggleStar('alpha');

      expect(repo.starCalls, [('alpha', false)]);
    });

    test('a failed star still refreshes and leaves the server list', () async {
      final repo = FakeBoardsRepository(boards: [makeBoard('alpha')])
        ..starError = const ApiException('offline');
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);

      await c.read(boardsProvider.notifier).toggleStar('alpha');

      expect(repo.calls, 2);
      expect(c.read(boardsProvider), isA<AsyncData<List<BoardSummary>>>());
      expect(slugs(c), ['alpha']);
      expect(stars(c), [false]);
    });

    test('a 404 star refreshes and drops the gone row', () async {
      final repo = FakeBoardsRepository(
        boards: [makeBoard('alpha'), makeBoard('beta')],
      )..starError = const ApiException('Not found', statusCode: 404);
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);
      repo.boards = [makeBoard('alpha')];

      await c.read(boardsProvider.notifier).toggleStar('beta');

      expect(slugs(c), ['alpha']);
    });
  });

  group('toggleMute (RE406)', () {
    List<String> slugs(ProviderContainer c) =>
        c.read(boardsProvider).value!.map((b) => b.slug).toList();
    List<bool> mutes(ProviderContainer c) =>
        c.read(boardsProvider).value!.map((b) => b.muted).toList();

    test('mutes an unmuted board, then renders the server list', () async {
      final repo =
          FakeBoardsRepository(boards: [makeBoard('alpha'), makeBoard('beta')])
            ..onMute = (r) =>
                r.boards = [makeBoard('alpha'), makeBoard('beta', muted: true)];
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);

      await c.read(boardsProvider.notifier).toggleMute('beta');

      expect(repo.muteCalls, [('beta', true)]);
      expect(repo.calls, 2);
      expect(slugs(c), ['alpha', 'beta']);
      expect(mutes(c), [false, true]);
    });

    test('unmutes a muted board', () async {
      final repo = FakeBoardsRepository(
        boards: [makeBoard('alpha', muted: true)],
      );
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);

      await c.read(boardsProvider.notifier).toggleMute('alpha');

      expect(repo.muteCalls, [('alpha', false)]);
    });

    test('a failed mute still refreshes and leaves the server list', () async {
      final repo = FakeBoardsRepository(boards: [makeBoard('alpha')])
        ..muteError = const ApiException('offline');
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);

      await c.read(boardsProvider.notifier).toggleMute('alpha');

      expect(repo.calls, 2);
      expect(c.read(boardsProvider), isA<AsyncData<List<BoardSummary>>>());
      expect(slugs(c), ['alpha']);
      expect(mutes(c), [false]);
    });

    test('a 404 mute refreshes and drops the gone row', () async {
      final repo = FakeBoardsRepository(
        boards: [makeBoard('alpha'), makeBoard('beta')],
      )..muteError = const ApiException('Not found', statusCode: 404);
      final c = containerWith(repo: repo, prefs: InMemoryBoardPrefs('alpha'));
      await c.read(boardsProvider.future);
      repo.boards = [makeBoard('alpha')];

      await c.read(boardsProvider.notifier).toggleMute('beta');

      expect(slugs(c), ['alpha']);
    });
  });
}
