import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Replays a canned response and records what was asked for. Mirrors
/// push_service_test's RecordingAdapter (the repo's structural-seam convention),
/// but lets a test choose the status/body or fail the request outright.
class StubAdapter implements HttpClientAdapter {
  StubAdapter({this.statusCode = 200, this.body = const {}, this.failure});

  final int statusCode;
  final Map<String, dynamic> body;

  /// When set, every request throws this instead of answering — the network-error path.
  final Object? failure;

  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (failure != null) throw failure!;
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
