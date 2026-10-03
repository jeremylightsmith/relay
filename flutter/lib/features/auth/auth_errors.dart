import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_controller.dart';

/// Thrown when the backend refuses a provider token we successfully obtained —
/// a Google ID token or an Apple identity token, per [method].
/// Carries only the status code: the response body is never rendered, and
/// keeping it off the exception keeps it out of `toString()` by construction.
class SignInRejected implements Exception {
  const SignInRejected(this.statusCode, {this.method = SignInMethod.google});

  final int? statusCode;
  final SignInMethod method;

  @override
  String toString() =>
      'SignInRejected(statusCode: $statusCode, method: ${method.name})';
}

/// Dio failure types that all mean "we never reached Relay".
const _connectivityFailures = {
  DioExceptionType.connectionError,
  DioExceptionType.connectionTimeout,
  DioExceptionType.receiveTimeout,
  DioExceptionType.sendTimeout,
};

/// Maps a caught sign-in error to what the user should read.
///
/// Returns `null` for user cancellation — there is nothing to apologise for, so
/// the caller resets to a clean [AuthState] and shows no error at all.
String? signInErrorMessage(Object error) {
  if (error is GoogleSignInException &&
      error.code == GoogleSignInExceptionCode.canceled) {
    return null;
  }
  if (error is SignInWithAppleAuthorizationException &&
      error.code == AuthorizationErrorCode.canceled) {
    return null;
  }
  if (error is DioException && _connectivityFailures.contains(error.type)) {
    return "Couldn't reach Relay. Check your connection and try again.";
  }
  if (error is SignInRejected) {
    return switch (error.method) {
      SignInMethod.google =>
        "Relay couldn't sign you in with that Google account.",
      SignInMethod.apple => "Relay couldn't sign you in with that Apple ID.",
    };
  }
  return 'Something went wrong signing you in. Please try again.';
}
