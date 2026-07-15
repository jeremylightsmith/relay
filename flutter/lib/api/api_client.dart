import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config.dart';

/// A failed call to the JSON API, surfaced to the UI as a message rather than a
/// raw DioException. [statusCode] is null for transport failures (offline, DNS).
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException(${statusCode ?? 'transport'}): $message';
}

/// No bearer token available (D5). Distinct so the inbox can say *why* it can't
/// load instead of rendering an empty — i.e. "caught up" — queue.
class MissingTokenException extends ApiException {
  const MissingTokenException()
    : super(
        'Signed in, but no API token was returned — the inbox cannot load. '
        '(RLY-78 must return a bearer token from sign-in.)',
      );
}

/// Attaches `Authorization: Bearer <token>` when a token exists, and omits the
/// header entirely when it does not. Reads the token per-request via [tokenReader]
/// so a token arriving after client construction is picked up without a rebuild.
class BearerInterceptor extends Interceptor {
  BearerInterceptor(this.tokenReader);

  final String? Function() tokenReader;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = tokenReader();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }
}

/// The shared client for the bearer-authenticated `/api/all/*` scope (RLY-80).
///
/// Deliberately its own Dio, not the cookie-jar client in `features/auth/http_providers.dart`:
/// that one carries the session cookie for `/api/auth/*`, while `/api/all/*` is bearer-only
/// (chosen to avoid a CSRF surface). Introduced here because RLY-85 is the first native
/// surface to call it; RLY-87 / 88 / 89 are expected to reuse it.
class ApiClient {
  ApiClient({
    required String? Function() tokenReader,
    Dio? dio,
    String? baseUrl,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl ?? AppConfig.baseUrl,
               // Treat 4xx as a normal response so we can read the error body.
               validateStatus: (s) => s != null && s < 500,
             ),
           ) {
    _dio.interceptors.add(BearerInterceptor(tokenReader));
  }

  final Dio _dio;

  /// Exposed so tests can swap the adapter.
  Dio get dio => _dio;

  /// GETs [path] and returns the decoded JSON body, or throws [ApiException].
  Future<dynamic> getJson(String path) async {
    try {
      final resp = await _dio.get<dynamic>(path);
      if (resp.statusCode != 200) {
        throw ApiException(
          _messageFrom(resp.data) ?? 'Request failed (${resp.statusCode}).',
          statusCode: resp.statusCode,
        );
      }
      return resp.data;
    } on DioException catch (e) {
      throw ApiException(e.message ?? 'Network error — could not reach Relay.');
    }
  }

  String? _messageFrom(dynamic body) {
    if (body is Map && body['error'] is Map) {
      return (body['error'] as Map)['message'] as String?;
    }
    return null;
  }
}

/// The bearer token seam (D5). A plain provider so tests override it with a value
/// instead of driving the whole Google sign-in flow.
///
/// Always null in production for now: nothing mints a bearer (`relayu_`) token yet
/// — that is RLY-80/RLY-87's job, not RLY-86's (see AuthState, which carries no
/// token). `ref` stays unused until that lands.
final authTokenProvider = Provider<String?>((ref) => null);

final apiClientProvider = Provider<ApiClient>(
  (ref) => ApiClient(tokenReader: () => ref.read(authTokenProvider)),
);
