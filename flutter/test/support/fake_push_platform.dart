import 'package:relay_mobile/features/push/push_platform.dart';

/// A fake PushPlatform — no MethodChannel, no OS. The repo has no mocking
/// package and no ProviderScope-override idiom, so seams are structural.
class FakePushPlatform implements PushPlatform {
  FakePushPlatform({
    this.tokenToReturn,
    this.authorizedToken,
    this.status = PushAuthorizationStatus.notDetermined,
    this.statusError,
  });

  /// What `requestPermissionAndToken()` resolves to — the AUTH-03 "Allow" path.
  final String? tokenToReturn;

  /// What `tokenIfAuthorized()` resolves to — the silent re-register path (RLY-84).
  final String? authorizedToken;

  /// What `authorizationStatus()` reports (RLY-84).
  final PushAuthorizationStatus status;

  /// When set, `authorizationStatus()` throws this instead of returning — the
  /// "status unavailable" row of RLY-84's gating matrix.
  final Object? statusError;

  int requestCount = 0;
  int statusCount = 0;
  int tokenIfAuthorizedCount = 0;
  void Function(Map<String, dynamic>)? tapHandler;

  /// The payload the app was cold-started from, if any.
  Map<String, dynamic>? initial;

  @override
  Future<String?> requestPermissionAndToken() async {
    requestCount++;
    return tokenToReturn;
  }

  @override
  Future<PushAuthorizationStatus> authorizationStatus() async {
    statusCount++;
    if (statusError != null) throw statusError!;
    return status;
  }

  @override
  Future<String?> tokenIfAuthorized() async {
    tokenIfAuthorizedCount++;
    return authorizedToken;
  }

  @override
  Future<Map<String, dynamic>?> initialNotification() async => initial;

  @override
  void onNotificationTap(void Function(Map<String, dynamic>) handler) {
    tapHandler = handler;
  }
}
