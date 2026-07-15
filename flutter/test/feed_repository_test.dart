import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'api_client_test.dart' show FakeAdapter, jsonBody;

FeedRepository repoWith(FakeAdapter adapter, {String? token = 't'}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  final client = ApiClient(tokenReader: () => token, dio: dio);
  client.dio.httpClientAdapter = adapter;
  return FeedRepository(client);
}

Map<String, dynamic> row(String ref, {String kind = 'in_review'}) => {
  'ref': ref,
  'title': 'Card $ref',
  'board': {'name': 'Relay', 'key': 'RLY', 'slug': 'relay'},
  'tag': null,
  'status': kind,
  'kind': kind,
  'reason': 'Review',
  'blocked_at': '2026-07-15T09:00:00',
  'questions': null,
};

void main() {
  test('GETs /api/all/feed and parses the merged row shape', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': [row('RLY-1'), row('RLY-2', kind: 'needs_input')],
        'meta': {'count': 2},
      }),
    );

    final page = await repoWith(adapter).fetchFeed();

    expect(adapter.requests.single.path, '/api/all/feed');
    expect(page.rows.map((r) => r.ref), ['RLY-1', 'RLY-2']);
    expect(page.rows[1].kindLabel, 'NEEDS INPUT');
    expect(page.meta.count, 2);
    expect(page.meta.workingCount, isNull);
  });

  test('preserves server order — no client re-sort', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': [row('RLY-9'), row('RLY-3'), row('RLY-5')],
        'meta': {'count': 3},
      }),
    );

    final page = await repoWith(adapter).fetchFeed();

    expect(page.rows.map((r) => r.ref), ['RLY-9', 'RLY-3', 'RLY-5']);
  });

  test(
    'a 401 surfaces as ApiException rather than escaping to the UI',
    () async {
      final adapter = FakeAdapter(
        (_) async => jsonBody({
          'error': {
            'code': 'unauthorized',
            'message': 'Invalid or missing user token',
          },
        }, status: 401),
      );

      await expectLater(
        repoWith(adapter, token: 'bad').fetchFeed(),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
        ),
      );
    },
  );
}
