import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import 'feed_repository.dart';
import 'models/feed_row.dart';

/// The loaded inbox. Loading and failure live in the surrounding AsyncValue, so
/// this only ever describes a *successful* fetch.
class FeedState {
  const FeedState({required this.rows, required this.meta});

  final List<FeedRow> rows;
  final FeedMeta meta;

  int get count => meta.count;

  /// D3: the board chip appears only when the loaded feed spans >1 board.
  bool get multiBoard => rows.map((r) => r.board.key).toSet().length > 1;

  bool get caughtUp => rows.isEmpty;
}

/// Injectable clock (RLY-128): [FeedController.refreshIfStale]'s staleness guard
/// reads time through this seam so tests can age the feed without sleeping.
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Owns the inbox's state and refresh policy (D2). No HTTP — that's FeedRepository.
///
/// Freshness is manual + foreground + focus-triggered (RLY-128): pull-to-refresh,
/// app resume, regaining focus (throttled by [refreshIfStale]'s 15s guard), and
/// an optimistic [removeRow] + background reconcile after every decision. There
/// is still no realtime channel.
class FeedController extends AsyncNotifier<FeedState> {
  /// When the last *successful* page landed — via [_load] or [applyFeed]. Null
  /// until something has landed, so a never-loaded feed is always stale.
  DateTime? lastFetchedAt;

  bool _fetching = false;

  @override
  Future<FeedState> build() => _load();

  Future<FeedState> _load() async {
    // D5: no token → a typed failure, so the UI shows *why* rather than an empty
    // queue that reads as "caught up". Checked here so we never fire a doomed request.
    final token = ref.read(authTokenProvider);
    if (token == null || token.isEmpty) throw const MissingTokenException();

    _fetching = true;
    try {
      final page = await ref.read(feedRepositoryProvider).fetchFeed();
      lastFetchedAt = ref.read(clockProvider)();
      return FeedState(rows: page.rows, meta: page.meta);
    } finally {
      _fetching = false;
    }
  }

  /// Refetch the feed. **Public on purpose** — this is the seam RLY-81/F5 calls when
  /// a push lands while the app is open, so the list matches the badge.
  ///
  /// State only changes once the fetch settles, so existing rows stay visible
  /// underneath the RefreshIndicator's spinner.
  Future<void> refresh() async {
    state = await AsyncValue.guard(_load);
  }

  /// RLY-128 D1: the focus-triggered refresh. Skips when the current page is
  /// younger than [maxAge] or a fetch is already in flight; otherwise delegates
  /// to [refresh]. Explicit user intent (pull-to-refresh, Retry) and the
  /// app-resume hook keep calling [refresh] directly — the guard is only for
  /// focus events, which can arrive in bursts (tab bounce, pop chains).
  Future<void> refreshIfStale({
    Duration maxAge = const Duration(seconds: 15),
  }) async {
    if (_fetching) return;
    final last = lastFetchedAt;
    if (last != null && ref.read(clockProvider)().difference(last) < maxAge) {
      return;
    }
    await refresh();
  }

  /// RLY-128 D2: optimistically drop a decided row the moment its POST settles.
  /// Refs are only unique per board, so the match needs both. No-op when the
  /// row is absent or the state isn't data. The badge (needsYouCountProvider)
  /// follows automatically since it derives from meta.count.
  void removeRow({required String ref, required String boardSlug}) {
    final current = state;
    if (current is! AsyncData<FeedState>) return;
    final s = current.value;
    final rows = s.rows
        .where((r) => !(r.ref == ref && r.board.slug == boardSlug))
        .toList(growable: false);
    if (rows.length == s.rows.length) return;
    state = AsyncValue.data(
      FeedState(
        rows: rows,
        meta: FeedMeta(
          count: s.meta.count > 0 ? s.meta.count - 1 : 0,
          workingCount: s.meta.workingCount,
        ),
      ),
    );
  }

  /// Adopt a page the caller already fetched. RLY-89: the review-queue walk's own
  /// end-of-snapshot refetch (`ReviewQueue.advanceAfter`) lands exactly the rows
  /// this inbox needs at exactly the moment it needs them — this is the seam that
  /// hands them over without a second, redundant request. RLY-128: a handed-over
  /// page is exactly as fresh as one we fetched ourselves, so it stamps
  /// [lastFetchedAt] too.
  void applyFeed(FeedPage page) {
    lastFetchedAt = ref.read(clockProvider)();
    state = AsyncValue.data(FeedState(rows: page.rows, meta: page.meta));
  }
}

final feedControllerProvider = AsyncNotifierProvider<FeedController, FeedState>(
  FeedController.new,
  // Riverpod 3 retries a failed `build()` automatically (exponential backoff, up
  // to 10 attempts) unless told otherwise. That would fire background requests
  // the user never asked for and race the explicit Retry button/pull-to-refresh
  // below, so this provider opts out — refresh is always user- or lifecycle-driven.
  retry: (_, _) => null,
);

/// The in-app tab badge count (D6). 0 while loading or errored — an unknown queue
/// must not light the "you have work" dot.
final needsYouCountProvider = Provider<int>(
  (ref) => ref.watch(feedControllerProvider).value?.count ?? 0,
);
