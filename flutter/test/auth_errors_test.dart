import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:relay_mobile/features/auth/auth_errors.dart';

DioException _dioError(DioExceptionType type) => DioException(
  requestOptions: RequestOptions(path: '/api/auth/native/google'),
  type: type,
);

void main() {
  test('a cancelled Google sheet stays silent', () {
    expect(
      signInErrorMessage(
        const GoogleSignInException(code: GoogleSignInExceptionCode.canceled),
      ),
      isNull,
    );
  });

  test('connection-ish Dio failures read as a connectivity problem', () {
    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
    ]) {
      expect(
        signInErrorMessage(_dioError(type)),
        "Couldn't reach Relay. Check your connection and try again.",
        reason: '$type should read as a connectivity problem',
      );
    }
  });

  test('a backend rejection names the account, not the status code', () {
    expect(
      signInErrorMessage(const SignInRejected(403)),
      "Relay couldn't sign you in with that Google account.",
    );
  });

  test('an unknown error falls back and never leaks the raw text', () {
    final message = signInErrorMessage(Exception('boom: secret internals'));
    expect(message, 'Something went wrong signing you in. Please try again.');
    expect(message, isNot(contains('secret internals')));
    expect(message, isNot(contains('boom')));
  });

  test('a non-cancel Google failure falls back rather than staying silent', () {
    expect(
      signInErrorMessage(
        const GoogleSignInException(
          code: GoogleSignInExceptionCode.unknownError,
        ),
      ),
      'Something went wrong signing you in. Please try again.',
    );
  });

  test(
    'a bad-response Dio failure is not mistaken for a connectivity problem',
    () {
      expect(
        signInErrorMessage(_dioError(DioExceptionType.badResponse)),
        'Something went wrong signing you in. Please try again.',
      );
    },
  );
}
