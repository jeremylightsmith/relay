import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_api.dart';

import 'api_client_test.dart' show FakeAdapter, clientWith, jsonBody;

BoardApi apiWith(FakeAdapter adapter) =>
    BoardApi(clientWith(adapter, token: 'relayu_t'));

ResponseBody error(String code, String message, {required int status}) =>
    jsonBody({
      'error': {'code': code, 'message': message},
    }, status: status);

void main() {
  test('createCard POSTs board, stage, title, and description', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': {'ref': 'RLY-9', 'title': 'Fix the footer'},
      }, status: 201),
    );

    final result = await apiWith(adapter).createCard(
      board: 'relay',
      stage: 'Backlog',
      title: 'Fix the footer',
      description: 'the details',
    );

    expect(adapter.requests.single.path, '/api/all/cards');
    expect(adapter.requests.single.data, {
      'board': 'relay',
      'stage': 'Backlog',
      'title': 'Fix the footer',
      'description': 'the details',
    });
    expect(result, isA<CreateCardOk>());
    expect((result as CreateCardOk).card['data']['ref'], 'RLY-9');
  });

  test('a blank description is omitted from the body', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': {'ref': 'RLY-9'},
      }, status: 201),
    );

    await apiWith(adapter).createCard(
      board: 'relay',
      stage: 'Backlog',
      title: 'Fix the footer',
      description: '   ',
    );

    expect(adapter.requests.single.data, {
      'board': 'relay',
      'stage': 'Backlog',
      'title': 'Fix the footer',
    });
  });

  // Every code the FallbackController can emit on this route.
  for (final (code, status) in const [
    ('missing_title', 422),
    ('invalid_stage', 422),
    ('not_found', 404),
    ('unauthorized', 401),
  ]) {
    test('a $status $code maps to CreateCardFailed($code)', () async {
      final adapter = FakeAdapter(
        (_) async => error(code, 'server says $code', status: status),
      );

      final result = await apiWith(
        adapter,
      ).createCard(board: 'relay', stage: 'Backlog', title: 'x');

      expect(result, isA<CreateCardFailed>());
      expect((result as CreateCardFailed).code, code);
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
    ).createCard(board: 'relay', stage: 'Backlog', title: 'x');

    expect((result as CreateCardFailed).code, 'network');
  });
}
