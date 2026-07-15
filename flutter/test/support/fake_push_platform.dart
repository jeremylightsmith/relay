import 'package:relay_mobile/features/push/push_platform.dart';

/// A fake PushPlatform — no MethodChannel, no OS. The repo has no mocking
/// package and no ProviderScope-override idiom, so seams are structural.
class FakePushPlatform implements PushPlatform {
  FakePushPlatform({this.tokenToReturn});

  final String? tokenToReturn;
  int requestCount = 0;
  void Function(Map<String, dynamic>)? tapHandler;

  /// The payload the app was cold-started from, if any.
  Map<String, dynamic>? initial;

  @override
  Future<String?> requestPermissionAndToken() async {
    requestCount++;
    return tokenToReturn;
  }

  @override
  Future<Map<String, dynamic>?> initialNotification() async => initial;

  @override
  void onNotificationTap(void Function(Map<String, dynamic>) handler) {
    tapHandler = handler;
  }
}
