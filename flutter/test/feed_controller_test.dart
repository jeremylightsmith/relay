import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/needs_you/feed_controller.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository, makeRow;

/// Never answers until the test says so — the only way to observe an
/// in-flight fetch.
class BlockedFeedRepository implements FeedRepository {
  final completer = Completer<FeedPage>();
  int calls = 0;

  @override
  Future<FeedPage> fetchFeed() {
    calls++;
    return completer.future;
  }
}

ProviderContainer harness({
  required FeedRepository repo,
  DateTime Function()? clock,
}) {
  final container = ProviderContainer(
    overrides: [
      feedRepositoryProvider.overrideWithValue(repo),
      authTokenProvider.overrideWithValue('relayu_test'),
      if (clock != null) clockProvider.overrideWithValue(clock),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

FeedPage feedPage(List<FeedRow> rows) => FeedPage(
  rows: rows,
  meta: FeedMeta(count: rows.length),
);

void main() {
  test('refreshIfStale refetches once the page is older than maxAge', () async {
    var now = DateTime.utc(2026, 7, 16, 12);
    final repo = FakeFeedRepository(page: feedPage([makeRow(ref: 'RLY-1')]));
    final container = harness(repo: repo, clock: () => now);

    await container.read(feedControllerProvider.future);
    expect(repo.calls, 1);

    now = now.add(const Duration(seconds: 16));
    await container.read(feedControllerProvider.notifier).refreshIfStale();

    expect(repo.calls, 2);
  });

  test('refreshIfStale inside maxAge is a no-op', () async {
    var now = DateTime.utc(2026, 7, 16, 12);
    final repo = FakeFeedRepository(page: feedPage([makeRow(ref: 'RLY-1')]));
    final container = harness(repo: repo, clock: () => now);

    await container.read(feedControllerProvider.future);
    now = now.add(const Duration(seconds: 14));
    await container.read(feedControllerProvider.notifier).refreshIfStale();

    expect(repo.calls, 1, reason: 'fetched 14s ago — the guard skips');
  });

  test('refreshIfStale fetches when nothing has ever landed', () async {
    final repo = FakeFeedRepository(error: const ApiException('down'));
    final container = harness(
      repo: repo,
      clock: () => DateTime.utc(2026, 7, 16, 12),
    );

    await expectLater(
      container.read(feedControllerProvider.future),
      throwsA(isA<ApiException>()),
    );
    expect(repo.calls, 1);

    repo.error = null;
    repo.page = feedPage([makeRow(ref: 'RLY-1')]);
    await container.read(feedControllerProvider.notifier).refreshIfStale();

    expect(repo.calls, 2, reason: 'a feed that never loaded is always stale');
    expect(
      container.read(feedControllerProvider).value!.rows.single.ref,
      'RLY-1',
    );
  });

  test(
    'refreshIfStale is a no-op while a fetch is already in flight',
    () async {
      final repo = BlockedFeedRepository();
      final container = harness(repo: repo);

      final first = container.read(feedControllerProvider.future);
      await container.read(feedControllerProvider.notifier).refreshIfStale();
      expect(repo.calls, 1, reason: 'the in-flight build is the only fetch');

      repo.completer.complete(feedPage([makeRow(ref: 'RLY-1')]));
      await first;
      expect(container.read(feedControllerProvider).value!.rows, hasLength(1));
    },
  );

  test('removeRow drops the matched row, decrements the count, and the badge '
      'follows', () async {
    final repo = FakeFeedRepository(
      page: feedPage([makeRow(ref: 'RLY-1'), makeRow(ref: 'RLY-2')]),
    );
    final container = harness(repo: repo);
    await container.read(feedControllerProvider.future);
    expect(container.read(needsYouCountProvider), 2);

    container
        .read(feedControllerProvider.notifier)
        .removeRow(ref: 'RLY-1', boardSlug: 'rly');

    final state = container.read(feedControllerProvider).value!;
    expect(state.rows.map((r) => r.ref), ['RLY-2']);
    expect(state.count, 1);
    expect(container.read(needsYouCountProvider), 1);
    expect(repo.calls, 1, reason: 'removal is local — no fetch');
  });

  test('removing the last row reads as caught up', () async {
    final repo = FakeFeedRepository(page: feedPage([makeRow(ref: 'RLY-1')]));
    final container = harness(repo: repo);
    await container.read(feedControllerProvider.future);

    container
        .read(feedControllerProvider.notifier)
        .removeRow(ref: 'RLY-1', boardSlug: 'rly');

    final state = container.read(feedControllerProvider).value!;
    expect(state.caughtUp, isTrue);
    expect(state.count, 0);
    expect(container.read(needsYouCountProvider), 0);
  });

  test('removeRow matches on ref AND board slug — the same ref on another '
      'board stays', () async {
    final repo = FakeFeedRepository(
      page: feedPage([
        makeRow(ref: 'RLY-1', boardKey: 'RLY'),
        makeRow(ref: 'RLY-1', boardKey: 'MKT'),
      ]),
    );
    final container = harness(repo: repo);
    await container.read(feedControllerProvider.future);

    container
        .read(feedControllerProvider.notifier)
        .removeRow(ref: 'RLY-1', boardSlug: 'mkt');

    final state = container.read(feedControllerProvider).value!;
    expect(state.rows.single.board.slug, 'rly');
    expect(state.count, 1);
  });

  test('removeRow no-ops when the row is absent', () async {
    final repo = FakeFeedRepository(page: feedPage([makeRow(ref: 'RLY-1')]));
    final container = harness(repo: repo);
    await container.read(feedControllerProvider.future);

    container
        .read(feedControllerProvider.notifier)
        .removeRow(ref: 'RLY-404', boardSlug: 'rly');

    final state = container.read(feedControllerProvider).value!;
    expect(state.rows.single.ref, 'RLY-1');
    expect(state.count, 1);
  });

  test('removeRow no-ops when the state is not data', () async {
    final repo = FakeFeedRepository(error: const ApiException('down'));
    final container = harness(repo: repo);
    await expectLater(
      container.read(feedControllerProvider.future),
      throwsA(isA<ApiException>()),
    );

    container
        .read(feedControllerProvider.notifier)
        .removeRow(ref: 'RLY-1', boardSlug: 'rly');

    expect(container.read(feedControllerProvider).hasError, isTrue);
  });

  test(
    'applyFeed counts as fresh — a focus refresh right after is skipped',
    () async {
      var now = DateTime.utc(2026, 7, 16, 12);
      final repo = FakeFeedRepository(page: feedPage([makeRow(ref: 'RLY-1')]));
      final container = harness(repo: repo, clock: () => now);
      await container.read(feedControllerProvider.future);
      final notifier = container.read(feedControllerProvider.notifier);

      now = now.add(const Duration(seconds: 60)); // stale by the clock…
      notifier.applyFeed(feedPage([makeRow(ref: 'RLY-9')])); // …but fresh data
      await notifier.refreshIfStale();

      expect(
        repo.calls,
        1,
        reason: 'the handed-over page reset the staleness clock',
      );
      expect(
        container.read(feedControllerProvider).value!.rows.single.ref,
        'RLY-9',
      );
    },
  );
}
