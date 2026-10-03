import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../needs_you/feed_controller.dart';
import '../needs_you/models/feed_row.dart';
import 'board_summary.dart';
import 'boards_repository.dart';
import 'current_board.dart';

/// The user's boards (RE376). The switcher sheet, Choose a board, and board-name
/// lookups all read this list. Every successful load also reconciles the current
/// board against it ([CurrentBoard.reconcile]). That is where a deleted board or a
/// revoked membership gets noticed, and where a single-board user is auto-selected.
class BoardsController extends AsyncNotifier<List<BoardSummary>> {
  @override
  Future<List<BoardSummary>> build() {
    // A new session (sign-out, then sign-in as someone else) must not keep the
    // previous user's list.
    ref.watch(authTokenProvider);
    return _load();
  }

  Future<List<BoardSummary>> _load() async {
    // The feed's D5 posture: no token → a typed failure, never a doomed request.
    final token = ref.read(authTokenProvider);
    if (token == null || token.isEmpty) throw const MissingTokenException();

    final boards = await ref.read(boardsRepositoryProvider).fetchBoards();
    final current = ref.read(currentBoardProvider.notifier);
    await current.ready;
    await current.reconcile(boards.map((b) => b.slug).toList(growable: false));
    return boards;
  }

  /// Refetch. The sheet calls this each time it opens, and Needs you calls it on
  /// pull-to-refresh and app resume. The previous list stays readable while the
  /// new one loads.
  Future<void> refresh() async {
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      // Already surfaced through the AsyncError state; nothing to add here.
    }
  }
}

final boardsProvider = AsyncNotifierProvider<BoardsController, List<BoardSummary>>(
  BoardsController.new,
  // The feedControllerProvider posture: an automatic retry would fire requests
  // nobody asked for and race the sheet's own Retry.
  retry: (_, _) => null,
);

/// The current board's display name, or null when nothing knows it yet. The
/// board list is checked first, then the feed (its rows carry their board's
/// name), so the title is right before the list lands and also when the list
/// fails to load. Callers render a neutral placeholder for null and never block.
final currentBoardNameProvider = Provider<String?>((ref) {
  final slug = ref.watch(currentBoardProvider.select((s) => s.slug));
  if (slug == null) return null;
  for (final b in ref.watch(boardsProvider).value ?? const <BoardSummary>[]) {
    if (b.slug == slug) return b.name;
  }
  final rows =
      ref.watch(feedControllerProvider).value?.rows ?? const <FeedRow>[];
  for (final r in rows) {
    if (r.board.slug == slug) return r.board.name;
  }
  return null;
});
