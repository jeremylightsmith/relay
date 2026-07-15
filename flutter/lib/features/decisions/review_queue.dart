import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../auth/auth_controller.dart';
import '../needs_you/feed_repository.dart';
import '../needs_you/models/feed_row.dart';
import 'decision_api.dart';

/// One row of the snapshot the human is walking.
class QueueItem {
  const QueueItem({
    required this.ref,
    required this.boardSlug,
    required this.boardName,
    required this.title,
    required this.kind,
    this.stage,
    this.reason,
    this.questions,
  });

  factory QueueItem.fromRow(FeedRow row) => QueueItem(
    ref: row.ref,
    boardSlug: row.board.slug,
    boardName: row.board.name,
    title: row.title,
    kind: row.kind,
    stage: row.stage,
    reason: row.reason,
    questions: row.questions,
  );

  final String ref;
  final String boardSlug;

  /// INPUT-01's breadcrumb is `<Board> / <Stage>` (RLY-89).
  final String boardName;
  final String title;
  final String kind;
  final String? stage;

  /// The row's one-line "why it needs you". RLY-89: on a **legacy** needs_input row
  /// (`questions == null`) this IS the question — `FeedJSON.reason/1` renders it from
  /// the flattened `meta["question"]` — so it is what the free-text mode prompts with.
  final String? reason;

  /// RLY-89: the structured questions, straight off the feed snapshot — null on an
  /// in_review row and on a card blocked with a plain-string question.
  final List<FeedQuestion>? questions;
}

class ReviewQueueState {
  const ReviewQueueState({
    this.items = const [],
    this.index = 0,
    this.banner,
    this.error,
    this.inFlight = false,
  });

  final List<QueueItem> items;
  final int index;

  /// Consumed by the *next* screen (via [ReviewQueue.takeBanner]), so "Approved ·
  /// RLY-42" lands over the item you arrive at — never over a screen about to be
  /// replaced.
  final String? banner;

  /// Shown on the screen we stayed on, because the decision failed.
  final String? error;

  /// A decision is in flight. Approve/reject are irreversible and have no domain
  /// undo, so this is the double-tap guard (RLY-100 revisits mis-tap protection).
  final bool inFlight;

  QueueItem? get current =>
      index >= 0 && index < items.length ? items[index] : null;

  ReviewQueueState copyWith({
    List<QueueItem>? items,
    int? index,
    String? banner,
    String? error,
    bool? inFlight,
    bool clearBanner = false,
    bool clearError = false,
  }) => ReviewQueueState(
    items: items ?? this.items,
    index: index ?? this.index,
    banner: clearBanner ? null : (banner ?? this.banner),
    error: clearError ? null : (error ?? this.error),
    inFlight: inFlight ?? this.inFlight,
  );
}

/// The queue-clearing walk: decide, advance, repeat until the snapshot is empty.
///
/// **A snapshot, not a live list** (D3). `Cards.needs_you_feed/1` orders
/// most-recently-blocked first, so refetching and taking the top row would let a card
/// blocked *while you were deciding* jump the line and reorder the queue under you.
/// Snapshotting means you clear exactly what you saw, in the order you saw it.
///
/// Reused by RLY-89 for the needs-input auto-advance, so the name and shape are a
/// published contract.
class ReviewQueue extends Notifier<ReviewQueueState> {
  @override
  ReviewQueueState build() => const ReviewQueueState();

  /// Snapshot the feed's ordered rows and sit on [atRef].
  void enter({required List<FeedRow> rows, required String atRef}) {
    final items = rows.map(QueueItem.fromRow).toList(growable: false);
    final at = items.indexWhere((i) => i.ref == atRef);
    state = ReviewQueueState(items: items, index: at < 0 ? 0 : at);
  }

  /// Approve the current item. Returns where to navigate, or null to stay put.
  Future<String?> approveCurrent() async {
    final item = state.current;
    if (item == null || state.inFlight) return null;

    state = state.copyWith(inFlight: true, clearError: true);
    try {
      final result = await ref
          .read(decisionApiProvider)
          .approve(ref: item.ref, boardSlug: item.boardSlug);
      return await _settle(result, item, okBanner: 'Approved · ${item.ref}');
    } finally {
      state = state.copyWith(inFlight: false);
    }
  }

  /// Reject (send back) the current item with [note]. Same shape and policy as
  /// [approveCurrent] — routed through the same [_settle], so `not_in_review` and
  /// `unauthorized` behave identically regardless of which button the human
  /// pressed, and reject gets the [ReviewQueueState.inFlight] double-tap guard
  /// for free.
  ///
  /// [cardRef] and [boardSlug] are what the *route* believes it is rejecting —
  /// the reject screen is reachable by a deep link, whose `:ref`/`?board=` can
  /// disagree with `state.current` (a stale queue, or a genuine cold start with
  /// nothing snapshotted at all). Refs are only unique within a board, so both
  /// must match. A mismatch surfaces as `state.error` rather than silently
  /// returning null: an inert Send back button that never explains itself would
  /// otherwise look enabled and just do nothing forever.
  Future<String?> rejectCurrent({
    required String cardRef,
    required String boardSlug,
    required String note,
  }) async {
    if (state.inFlight) return null;
    final item = state.current;
    if (item == null || item.ref != cardRef || item.boardSlug != boardSlug) {
      state = state.copyWith(
        error:
            "This card isn't in your queue anymore — go back to Needs you "
            'and try again.',
      );
      return null;
    }

    state = state.copyWith(inFlight: true, clearError: true);
    try {
      final result = await ref
          .read(decisionApiProvider)
          .reject(ref: item.ref, boardSlug: item.boardSlug, note: note);
      return await _settle(result, item, okBanner: 'Sent back · ${item.ref}');
    } finally {
      state = state.copyWith(inFlight: false);
    }
  }

  /// Answer the current item. [answers] for a structured question (the stepper's
  /// positional picks), [text] for a legacy string one. Returns where to navigate, or
  /// null to stay put. Shares `_settle` with approve, so the skip, the 401 sign-out
  /// and the in-flight guard are the same code on both paths.
  Future<String?> answerCurrent({
    List<Map<String, String>>? answers,
    String? text,
  }) async {
    final item = state.current;
    if (item == null || state.inFlight) return null;

    state = state.copyWith(inFlight: true, clearError: true);
    try {
      final result = await ref
          .read(decisionApiProvider)
          .answer(
            ref: item.ref,
            boardSlug: item.boardSlug,
            answers: answers,
            text: text,
          );
      return await _settle(result, item, okBanner: 'Answer sent · ${item.ref}');
    } finally {
      state = state.copyWith(inFlight: false);
    }
  }

  Future<String?> _settle(
    DecisionResult result,
    QueueItem item, {
    required String okBanner,
  }) async {
    switch (result) {
      case DecisionOk():
        return advanceAfter(banner: okBanner);
      // Someone cleared it on the web while we walked. Not a failure.
      case DecisionFailed(code: 'not_in_review' || 'not_needs_input'):
        return advanceAfter(banner: 'Already handled · ${item.ref}');
      // The token expired or was revoked; the router sends a signed-out user to /welcome.
      case DecisionFailed(code: 'unauthorized'):
        await ref.read(authProvider.notifier).signOut();
        return null;
      case DecisionFailed(:final message):
        state = state.copyWith(error: message);
        return null;
    }
  }

  /// Record [banner] for the screen we land on, step the snapshot, and return the
  /// route to go to. At the end of the snapshot, refetch **once**: fresh rows
  /// re-snapshot at 0 and the walk continues; nothing fresh lands on the inbox,
  /// which renders EMPTY-01 (RLY-85's).
  Future<String> advanceAfter({required String banner}) async {
    final next = state.index + 1;
    if (next < state.items.length) {
      state = state.copyWith(index: next, banner: banner, clearError: true);
      return routeFor(state.items[next]);
    }

    final rows = await _refetch();
    if (rows.isEmpty) {
      state = ReviewQueueState(banner: banner);
      return '/needs-you';
    }

    final items = rows.map(QueueItem.fromRow).toList(growable: false);
    state = ReviewQueueState(items: items, banner: banner);
    return routeFor(items.first);
  }

  /// A feed we cannot reach is indistinguishable from an empty one *for this
  /// purpose*: either way the walk is over and the inbox is where to land — and the
  /// inbox has its own retry.
  Future<List<FeedRow>> _refetch() async {
    try {
      return (await ref.read(feedRepositoryProvider).fetchFeed()).rows;
    } on ApiException {
      return const [];
    }
  }

  /// The banner, once. Null afterwards, so the next screen does not re-show it.
  String? takeBanner() {
    final banner = state.banner;
    if (banner != null) state = state.copyWith(clearBanner: true);
    return banner;
  }

  void clearError() => state = state.copyWith(clearError: true);
}

final reviewQueueProvider = NotifierProvider<ReviewQueue, ReviewQueueState>(
  ReviewQueue.new,
);

/// Where a queue item is answered or reviewed. **The one routing rule** — the inbox tap
/// (`needs_you_screen`) and the queue's own advance must agree, or opening a card and
/// advancing to it would land on different screens.
///
/// needs_input → RLY-89's native answer screen. in_review → the card host, `kind`
/// riding along so it picks its bottom bar (RLY-85 · D4).
String routeFor(QueueItem item) => item.kind == 'needs_input'
    ? '/card/${item.ref}/answer'
    : '/card/${item.ref}?kind=${item.kind}';

/// Applies a destination from [ReviewQueue]. `/needs-you` goes back to the shell tab;
/// a card *replaces* the one just decided, so clearing a long queue never grows the
/// stack and Back still reaches the inbox.
void navigateQueue(GoRouter router, String dest) {
  if (dest == '/needs-you') {
    router.go(dest);
  } else {
    router.pushReplacement(dest);
  }
}
