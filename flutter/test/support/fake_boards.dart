import 'package:relay_mobile/features/boards/board_summary.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';

/// Answers `/api/all/boards` from memory and counts calls — no network, no Dio.
class FakeBoardsRepository implements BoardsRepository {
  FakeBoardsRepository({this.boards = const [], this.error});

  List<BoardSummary> boards;
  Object? error;
  int calls = 0;

  /// Every `setStarred` call, in order, as `(slug, starred)`.
  final List<(String, bool)> starCalls = [];

  /// Thrown from `setStarred` (after the call is recorded) when non-null.
  Object? starError;

  /// Runs after a recorded, non-failing `setStarred` — tests use it to set the
  /// server's next [boards] list.
  void Function(FakeBoardsRepository)? onStar;

  @override
  Future<List<BoardSummary>> fetchBoards() async {
    calls++;
    if (error != null) throw error!;
    return boards;
  }

  @override
  Future<bool> setStarred(String slug, bool starred) async {
    starCalls.add((slug, starred));
    if (starError != null) throw starError!;
    onStar?.call(this);
    return starred;
  }
}

BoardSummary makeBoard(
  String slug, {
  String? name,
  int needsYou = 0,
  int stages = 4,
  int cards = 9,
  bool aiActive = true,
  bool starred = false,
}) => BoardSummary(
  name: name ?? slug,
  slug: slug,
  key: slug.toUpperCase(),
  needsYouCount: needsYou,
  stageCount: stages,
  cardCount: cards,
  aiActive: aiActive,
  starred: starred,
);
