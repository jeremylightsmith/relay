import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';

import 'api_client_test.dart' show FakeAdapter, clientWith, jsonBody;

DecisionApi apiWith(FakeAdapter adapter) =>
    DecisionApi(clientWith(adapter, token: 'relayu_t'));

ResponseBody error(String code, String message, {required int status}) =>
    jsonBody({
      'error': {'code': code, 'message': message},
    }, status: status);

void main() {
  test('approve POSTs the ref and always sends the board slug', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': {'ref': 'RLY-42'},
      }),
    );

    final result = await apiWith(
      adapter,
    ).approve(ref: 'RLY-42', boardSlug: 'relay');

    expect(adapter.requests.single.path, '/api/all/cards/RLY-42/approve');
    expect(adapter.requests.single.data, {'board': 'relay'});
    expect(result, isA<DecisionOk>());
  });

  test('reject POSTs the note alongside the board slug', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': {'ref': 'RLY-42'},
      }),
    );

    final result = await apiWith(
      adapter,
    ).reject(ref: 'RLY-42', boardSlug: 'relay', note: 'Needs error handling');

    expect(adapter.requests.single.path, '/api/all/cards/RLY-42/reject');
    expect(adapter.requests.single.data, {
      'board': 'relay',
      'note': 'Needs error handling',
    });
    expect(result, isA<DecisionOk>());
  });

  test('a 200 carries the card body back', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': {'ref': 'RLY-42', 'status': 'approved'},
      }),
    );

    final result = await apiWith(
      adapter,
    ).approve(ref: 'RLY-42', boardSlug: 'relay');

    expect((result as DecisionOk).card['data']['status'], 'approved');
  });

  // Every code the FallbackController can emit on these two routes.
  for (final (code, status) in const [
    ('not_in_review', 422),
    ('missing_note', 422),
    ('ambiguous_ref', 422),
    ('not_found', 404),
    ('unauthorized', 401),
  ]) {
    test('a $status $code maps to DecisionFailed($code)', () async {
      final adapter = FakeAdapter(
        (_) async => error(code, 'server says $code', status: status),
      );

      final result = await apiWith(
        adapter,
      ).approve(ref: 'RLY-42', boardSlug: 'relay');

      expect(result, isA<DecisionFailed>());
      expect((result as DecisionFailed).code, code);
      expect(result.message, 'server says $code');
    });
  }

  test('a transport failure maps to the synthetic network code', () async {
    final adapter = FakeAdapter(
      (options) async => throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      ),
    );

    final result = await apiWith(
      adapter,
    ).approve(ref: 'RLY-42', boardSlug: 'relay');

    expect((result as DecisionFailed).code, 'network');
  });
}
