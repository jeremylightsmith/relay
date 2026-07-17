import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';

/// The outcome of a create. Sealed so callers must handle both arms.
sealed class CreateCardResult {
  const CreateCardResult();
}

/// The server created the card. [card] is the 201 card envelope.
class CreateCardOk extends CreateCardResult {
  const CreateCardOk(this.card);

  final Map<String, dynamic> card;
}

/// The server (or the network) refused. [code] is one of the FallbackController
/// codes — `missing_title`, `invalid_stage`, `not_found`, `unauthorized` — or the
/// synthetic `network` for a transport failure.
class CreateCardFailed extends CreateCardResult {
  const CreateCardFailed(this.code, this.message);

  final String code;
  final String message;
}

/// The only thing that talks to `POST /api/all/cards` (RLY-126). Pure I/O,
/// mirroring DecisionApi: it does not navigate, toast, or own the sheet.
class BoardApi {
  BoardApi(this._client);

  final ApiClient _client;

  Future<CreateCardResult> createCard({
    required String board,
    required String stage,
    required String title,
    String? description,
  }) async {
    try {
      final resp = await _client.postJson('/api/all/cards', {
        'board': board,
        'stage': stage,
        'title': title,
        if (description != null && description.trim().isNotEmpty)
          'description': description,
      });
      if (resp.statusCode == 201) {
        return CreateCardOk((resp.data as Map).cast<String, dynamic>());
      }
      return CreateCardFailed(
        _codeFrom(resp.data) ?? 'network',
        _messageFrom(resp.data) ?? 'Request failed (${resp.statusCode}).',
      );
    } on ApiException catch (e) {
      return CreateCardFailed('network', e.message);
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

final boardApiProvider = Provider<BoardApi>(
  (ref) => BoardApi(ref.watch(apiClientProvider)),
);
