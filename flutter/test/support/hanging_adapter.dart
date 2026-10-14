import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A request that never answers — the offline / unreachable-server case, where
/// only the caller's own timeout ends the wait. Records what was asked for,
/// like [StubAdapter].
class HangingAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}
