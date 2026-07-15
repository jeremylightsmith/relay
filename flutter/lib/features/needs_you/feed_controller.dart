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

/// Owns the inbox's state and refresh policy (D2). No HTTP — that's FeedRepository.
///
/// Freshness in V1 is manual + foreground: pull-to-refresh, app resume, and returning
/// from a card. There is no realtime channel.
class FeedController extends AsyncNotifier<FeedState> {
  @override
  Future<FeedState> build() => _load();

  Future<FeedState> _load() async {
    // D5: no token → a typed failure, so the UI shows *why* rather than an empty
    // queue that reads as "caught up". Checked here so we never fire a doomed request.
    final token = ref.read(authTokenProvider);
    if (token == null || token.isEmpty) throw const MissingTokenException();

    final page = await ref.read(feedRepositoryProvider).fetchFeed();
    return FeedState(rows: page.rows, meta: page.meta);
  }

  /// Refetch the feed. **Public on purpose** — this is the seam RLY-81/F5 calls when
  /// a push lands while the app is open, so the list matches the badge.
  ///
  /// State only changes once the fetch settles, so existing rows stay visible
  /// underneath the RefreshIndicator's spinner.
  Future<void> refresh() async {
    state = await AsyncValue.guard(_load);
  }

  /// Adopt a page the caller already fetched. RLY-89: the review-queue walk's own
  /// end-of-snapshot refetch (`ReviewQueue.advanceAfter`) lands exactly the rows
  /// this inbox needs at exactly the moment it needs them — this is the seam that
  /// hands them over without a second, redundant request.
  void applyFeed(FeedPage page) {
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
