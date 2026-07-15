import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Records requests and replays canned responses through dio's adapter seam.
///
/// Lifted out of push_service_test so the RLY-84 push tests can share it rather
/// than reach into another test file. Distinct from `StubAdapter` in
/// stub_adapter.dart, which additionally fakes chosen statuses and failures.
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
