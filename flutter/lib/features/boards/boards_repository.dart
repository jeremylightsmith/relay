import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import 'board_summary.dart';

/// The board switcher's list (RE376, `GET /api/all/boards`). HTTP + parsing only —
/// loading/refresh policy lives in BoardsController.
class BoardsRepository {
  BoardsRepository(this._client);

  final ApiClient _client;

  Future<List<BoardSummary>> fetchBoards() async {
    final body = await _client.getJson('/api/all/boards');
    final data = ((body as Map)['data'] as List<dynamic>?) ?? const [];
    return data
        .map((e) => BoardSummary.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false);
  }
}

final boardsRepositoryProvider = Provider<BoardsRepository>(
  (ref) => BoardsRepository(ref.watch(apiClientProvider)),
);
