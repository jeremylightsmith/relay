import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/card/card_summary.dart';

import 'support/stub_adapter.dart';

ProviderContainer containerWith(StubAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  final client = ApiClient(tokenReader: () => 'relayu_t', dio: dio);
  client.dio.httpClientAdapter = adapter;
  final container = ProviderContainer(
    overrides: [apiClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  return container;
}

const _key = (cardRef: 'RLY-1', boardSlug: 'relay');

Future<Uri?> fetch(ProviderContainer container) =>
    container.read(cardPrUrlProvider(_key).future);

Map<String, dynamic> summary(String? prUrl) => {
  'data': {'ref': 'RLY-1', 'pr_url': prUrl},
};

void main() {
  test('parses pr_url and passes the board tiebreak', () async {
    final adapter = StubAdapter(
      body: summary('https://github.com/acme/relay/pull/42'),
    );

    final uri = await fetch(containerWith(adapter));

    expect(uri, Uri.parse('https://github.com/acme/relay/pull/42'));
    final request = adapter.requests.single;
    expect(request.uri.path, '/api/all/cards/RLY-1');
    expect(request.uri.queryParameters['board'], 'relay');
  });

  test('a null or empty pr_url is no chip', () async {
    expect(
      await fetch(containerWith(StubAdapter(body: summary(null)))),
      isNull,
    );
    expect(await fetch(containerWith(StubAdapter(body: summary('')))), isNull);
  });

  test(
    'a non-web pr_url is no chip — the launch modes only take http(s)',
    () async {
      expect(
        await fetch(containerWith(StubAdapter(body: summary('not a url')))),
        isNull,
      );
      expect(
        await fetch(containerWith(StubAdapter(body: summary('ftp://x/y')))),
        isNull,
      );
    },
  );

  test('an API error degrades to no chip, never an error state', () async {
    final adapter = StubAdapter(
      statusCode: 401,
      body: {
        'error': {'code': 'missing_token', 'message': 'no'},
      },
    );

    expect(await fetch(containerWith(adapter)), isNull);
  });

  test('a transport failure degrades to no chip', () async {
    final adapter = StubAdapter(failure: const SocketException('offline'));

    expect(await fetch(containerWith(adapter)), isNull);
  });
}
