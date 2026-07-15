import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config.dart';

/// The session cookie store. F2's native sign-in writes `_relay_key` here; push
/// registration (RLY-81) reads it back by riding the same client.
final cookieJarProvider = Provider<CookieJar>((ref) => CookieJar());

/// The app's authenticated HTTP client. Hoisted out of AuthController so both
/// auth and push can share it without depending on each other (a cycle).
final dioProvider = Provider<Dio>((ref) {
  return Dio(
    BaseOptions(
      baseUrl: AppConfig.baseUrl,
      // Treat 4xx as a normal response so we can read the backend's error body.
      validateStatus: (s) => s != null && s < 500,
    ),
  )..interceptors.add(CookieManager(ref.watch(cookieJarProvider)));
});
