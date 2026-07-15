import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/push/push_service.dart';

import 'support/fake_push_platform.dart';

/// Records requests and replays canned responses through dio's adapter seam.
class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter({this.statusCode = 201, this.body = const {'ok': true}});

  final int statusCode;
  final Map<String, dynamic> body;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio dioWith(RecordingAdapter adapter) {
  return Dio(
    BaseOptions(
      baseUrl: 'http://localhost:4003',
      validateStatus: (s) => s != null && s < 500,
    ),
  )..httpClientAdapter = adapter;
}

void main() {
  test('enable() requests permission and registers the token', () async {
    final platform = FakePushPlatform(tokenToReturn: 'apns-tok-123');
    final adapter = RecordingAdapter();
    final service = PushService(platform: platform, dio: dioWith(adapter));

    expect(await service.enable(), isTrue);
    expect(platform.requestCount, 1);
    expect(service.token, 'apns-tok-123');

    expect(adapter.requests.length, 1);
    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.path, '/api/all/devices');
    expect(adapter.requests.single.data, {
      'token': 'apns-tok-123',
      'platform': 'ios',
    });
  });

  test('enable() registers nothing when permission is denied', () async {
    final platform = FakePushPlatform(tokenToReturn: null);
    final adapter = RecordingAdapter();
    final service = PushService(platform: platform, dio: dioWith(adapter));

    expect(await service.enable(), isFalse);
    expect(adapter.requests, isEmpty);
    expect(service.token, isNull);
  });

  test('enable() returns false when the backend rejects the token', () async {
    final platform = FakePushPlatform(tokenToReturn: 'apns-tok-123');
    final adapter = RecordingAdapter(statusCode: 401, body: {'error': 'nope'});
    final service = PushService(platform: platform, dio: dioWith(adapter));

    expect(await service.enable(), isFalse);
  });

  test('disable() unregisters the token', () async {
    final platform = FakePushPlatform(tokenToReturn: 'apns-tok-123');
    final adapter = RecordingAdapter(statusCode: 204, body: const {});
    final service = PushService(platform: platform, dio: dioWith(adapter));

    await service.disable('apns-tok-123');

    expect(adapter.requests.single.method, 'DELETE');
    expect(adapter.requests.single.path, '/api/all/devices/apns-tok-123');
    expect(service.token, isNull);
  });

  test('a network failure never throws out of enable()', () async {
    final platform = FakePushPlatform(tokenToReturn: 'apns-tok-123');
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'));
    final service = PushService(platform: platform, dio: dio);

    expect(await service.enable(), isFalse);
  });
}
