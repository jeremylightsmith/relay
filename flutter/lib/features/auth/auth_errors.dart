import 'package:dio/dio.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Thrown when the backend refuses a Google ID token we successfully obtained.
/// Carries only the status code: the response body is never rendered, and
/// keeping it off the exception keeps it out of `toString()` by construction.
class SignInRejected implements Exception {
  const SignInRejected(this.statusCode);

  final int? statusCode;

  @override
  String toString() => 'SignInRejected(statusCode: $statusCode)';
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
  if (error is DioException && _connectivityFailures.contains(error.type)) {
    return "Couldn't reach Relay. Check your connection and try again.";
  }
  if (error is SignInRejected) {
    return "Relay couldn't sign you in with that Google account.";
  }
  return 'Something went wrong signing you in. Please try again.';
}
