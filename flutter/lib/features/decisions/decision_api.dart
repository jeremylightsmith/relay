import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';

/// The outcome of an approve/reject. Sealed so callers must handle both arms.
sealed class DecisionResult {
  const DecisionResult();
}

/// The server acted. [card] is F4's card envelope for the acted-on card.
class DecisionOk extends DecisionResult {
  const DecisionOk(this.card);

  final Map<String, dynamic> card;
}

/// The server (or the network) refused. [code] is one of F4's FallbackController
/// codes — `not_in_review`, `missing_note`, `ambiguous_ref`, `not_found`,
/// `unauthorized` — or the synthetic `network` for a transport failure.
class DecisionFailed extends DecisionResult {
  const DecisionFailed(this.code, this.message);

  final String code;
  final String message;
}

/// The only thing that talks to F4's action endpoints (RLY-80). Pure I/O: it does
/// not navigate, toast, or touch the queue — that is [ReviewQueue]'s job.
class DecisionApi {
  DecisionApi(this._client);

  final ApiClient _client;

  Future<DecisionResult> approve({
    required String ref,
    required String boardSlug,
  }) => _post('/api/all/cards/$ref/approve', {'board': boardSlug});

  Future<DecisionResult> reject({
    required String ref,
    required String boardSlug,
    required String note,
  }) => _post('/api/all/cards/$ref/reject', {'board': boardSlug, 'note': note});

  /// `board` rides on every call: board keys are not unique, so F4 answers a bare
  /// ref with 422 ambiguous_ref. The feed hands every row its slug.
  Future<DecisionResult> _post(String path, Map<String, dynamic> body) async {
    try {
      final resp = await _client.postJson(path, body);
      if (resp.statusCode == 200) {
        return DecisionOk((resp.data as Map).cast<String, dynamic>());
      }
      return DecisionFailed(
        _codeFrom(resp.data) ?? 'network',
        _messageFrom(resp.data) ?? 'Request failed (${resp.statusCode}).',
      );
    } on ApiException catch (e) {
      return DecisionFailed('network', e.message);
    }
  }

  String? _codeFrom(dynamic body) => _errorField(body, 'code');

  String? _messageFrom(dynamic body) => _errorField(body, 'message');

  String? _errorField(dynamic body, String key) {
    if (body is Map && body['error'] is Map) {
      return (body['error'] as Map)[key] as String?;
    }
    return null;
  }
}

final decisionApiProvider = Provider<DecisionApi>(
  (ref) => DecisionApi(ref.watch(apiClientProvider)),
);
