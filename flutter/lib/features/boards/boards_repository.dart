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

  /// Sets (not toggles) the user's star on [slug] — `POST /api/all/boards/:slug/star`
  /// (RE396). Returns the server's resulting value. Any non-200 answer throws an
  /// [ApiException] carrying the status; a transport failure propagates as-is.
  Future<bool> setStarred(String slug, bool starred) async {
    final resp = await _client.postJson('/api/all/boards/$slug/star', {
      'starred': starred,
    });
    if (resp.statusCode == 200) {
      return ((resp.data as Map)['data'] as Map)['starred'] as bool;
    }
    throw ApiException(
      _messageFrom(resp.data) ?? 'Request failed (${resp.statusCode}).',
      statusCode: resp.statusCode,
    );
  }

  /// Sets (not toggles) the user's mute on [slug] — `POST /api/all/boards/:slug/mute`
  /// (RE406). Returns the server's resulting value. Any non-200 answer throws an
  /// [ApiException] carrying the status; a transport failure propagates as-is.
  Future<bool> setMuted(String slug, bool muted) async {
    final resp = await _client.postJson('/api/all/boards/$slug/mute', {
      'muted': muted,
    });
    if (resp.statusCode == 200) {
      return ((resp.data as Map)['data'] as Map)['muted'] as bool;
    }
    throw ApiException(
      _messageFrom(resp.data) ?? 'Request failed (${resp.statusCode}).',
      statusCode: resp.statusCode,
    );
  }

  String? _messageFrom(dynamic body) {
    if (body is Map && body['error'] is Map) {
      return (body['error'] as Map)['message'] as String?;
    }
    return null;
  }
}

final boardsRepositoryProvider = Provider<BoardsRepository>(
  (ref) => BoardsRepository(ref.watch(apiClientProvider)),
);
