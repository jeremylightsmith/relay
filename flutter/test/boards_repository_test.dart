import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/boards/board_summary.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';

import 'api_client_test.dart' show FakeAdapter, jsonBody;

BoardsRepository repoWith(FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  final client = ApiClient(tokenReader: () => 't', dio: dio);
  client.dio.httpClientAdapter = adapter;
  return BoardsRepository(client);
}

void main() {
  test('GETs /api/all/boards and parses the switcher fields', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': [
          {
            'name': 'Marketing site',
            'slug': 'marketing-site',
            'key': 'MKT',
            'needs_you_count': 2,
            'stage_count': 6,
            'card_count': 11,
            'ai_active': true,
          },
        ],
      }),
    );

    final boards = await repoWith(adapter).fetchBoards();

    expect(adapter.requests.single.path, '/api/all/boards');
    final b = boards.single;
    expect(b.name, 'Marketing site');
    expect(b.slug, 'marketing-site');
    expect(b.key, 'MKT');
    expect(b.needsYouCount, 2);
    expect(b.stageCount, 6);
    expect(b.cardCount, 11);
    expect(b.aiActive, isTrue);
    // No `starred` key → not starred (RE396).
    expect(b.starred, isFalse);
    // BOARDS-00's meta line, as card mockup "B — always in one board, switch from the title" draws it.
    expect(b.metaLabel, '6 stages · 11 cards · AI active');
  });

  test('the meta line says idle when no AI is active', () {
    const b = BoardSummary(
      name: 'Support triage',
      slug: 'support-triage',
      key: 'SUP',
      needsYouCount: 0,
      stageCount: 3,
      cardCount: 2,
      aiActive: false,
    );
    expect(b.metaLabel, '3 stages · 2 cards · idle');
  });

  test('a non-200 answer surfaces as an ApiException', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'error': {'code': 'unauthorized', 'message': 'nope'},
      }, status: 401),
    );

    expect(repoWith(adapter).fetchBoards(), throwsA(isA<ApiException>()));
  });

  test('parses starred, defaulting an absent key to false', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': [
          {'name': 'A', 'slug': 'a', 'starred': true},
          {'name': 'Marketing site', 'slug': 'marketing-site', 'key': 'MKT'},
        ],
      }),
    );

    final boards = await repoWith(adapter).fetchBoards();

    expect(boards.first.starred, isTrue);
    expect(boards.last.starred, isFalse);
  });

  test('setStarred POSTs the value to the star endpoint (RE396)', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': {'slug': 'alpha', 'starred': true},
      }),
    );

    final result = await repoWith(adapter).setStarred('alpha', true);

    final req = adapter.requests.single;
    expect(req.method, 'POST');
    expect(req.path, '/api/all/boards/alpha/star');
    expect(req.data, {'starred': true});
    expect(result, isTrue);
  });

  test('setStarred surfaces a non-200 as an ApiException with its status', () {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'error': {'code': 'not_found', 'message': 'Not found'},
      }, status: 404),
    );

    expect(
      repoWith(adapter).setStarred('gone', true),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
  });
}
