import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';

/// A hand-rolled adapter so tests never touch the network and can assert on the
/// exact RequestOptions dio built. Avoids adding an http_mock_adapter dependency.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ApiClient clientWith(FakeAdapter adapter, {String? token}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  );
  final client = ApiClient(tokenReader: () => token, dio: dio);
  client.dio.httpClientAdapter = adapter;
  return client;
}

void main() {
  test(
    'attaches Authorization: Bearer <token> when a token is present',
    () async {
      final adapter = FakeAdapter(
        (_) async => jsonBody({
          'data': [],
          'meta': {'count': 0},
        }),
      );
      await clientWith(adapter, token: 'relayu_abc').getJson('/api/all/feed');

      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer relayu_abc',
      );
    },
  );

  test('omits the Authorization header when the token is null', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': [],
        'meta': {'count': 0},
      }),
    );
    await clientWith(adapter, token: null).getJson('/api/all/feed');

    expect(
      adapter.requests.single.headers.containsKey('Authorization'),
      isFalse,
    );
  });

  test('returns the decoded body on 200', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'data': [],
        'meta': {'count': 7},
      }),
    );
    final body = await clientWith(adapter, token: 't').getJson('/api/all/feed');

    expect((body as Map)['meta']['count'], 7);
  });

  test('a non-200 becomes a typed ApiException carrying the status', () async {
    final adapter = FakeAdapter(
      (_) async => jsonBody({
        'error': {
          'code': 'unauthorized',
          'message': 'Invalid or missing user token',
        },
      }, status: 401),
    );

    await expectLater(
      clientWith(adapter, token: 'bad').getJson('/api/all/feed'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      ),
    );
  });

  test(
    'a transport failure becomes an ApiException, not a raw DioException',
    () async {
      final adapter = FakeAdapter(
        (options) async => throw DioException.connectionError(
          requestOptions: options,
          reason: 'offline',
        ),
      );

      await expectLater(
        clientWith(adapter, token: 't').getJson('/api/all/feed'),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
