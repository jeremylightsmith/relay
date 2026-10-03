import 'package:relay_mobile/features/boards/board_summary.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';

/// Answers `/api/all/boards` from memory and counts calls — no network, no Dio.
class FakeBoardsRepository implements BoardsRepository {
  FakeBoardsRepository({this.boards = const [], this.error});

  List<BoardSummary> boards;
  Object? error;
  int calls = 0;

  @override
  Future<List<BoardSummary>> fetchBoards() async {
    calls++;
    if (error != null) throw error!;
    return boards;
  }
}

BoardSummary makeBoard(
  String slug, {
  String? name,
  int needsYou = 0,
  int stages = 4,
  int cards = 9,
  bool aiActive = true,
}) => BoardSummary(
  name: name ?? slug,
  slug: slug,
  key: slug.toUpperCase(),
  needsYouCount: needsYou,
  stageCount: stages,
  cardCount: cards,
  aiActive: aiActive,
);
