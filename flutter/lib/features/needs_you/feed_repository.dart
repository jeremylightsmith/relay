import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import 'models/feed_row.dart';

/// F4's cross-board decision feed (RLY-80). HTTP + parsing only — the refresh
/// policy lives in FeedController.
class FeedRepository {
  FeedRepository(this._client);

  final ApiClient _client;

  Future<FeedPage> fetchFeed() async {
    final body = await _client.getJson('/api/all/feed');
    return FeedPage.fromJson((body as Map).cast<String, dynamic>());
  }
}

final feedRepositoryProvider = Provider<FeedRepository>(
  (ref) => FeedRepository(ref.watch(apiClientProvider)),
);
