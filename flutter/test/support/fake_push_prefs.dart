import 'package:relay_mobile/features/push/push_prefs.dart';

/// An in-memory PushPrefs — what we remember about having asked (RLY-84),
/// as opposed to what iOS thinks (FakePushPlatform).
class FakePushPrefs implements PushPrefs {
  FakePushPrefs({this.deferredAt});

  DateTime? deferredAt;
  int writeCount = 0;

  @override
  Future<DateTime?> primingDeferredAt() async => deferredAt;

  @override
  Future<void> setPrimingDeferredAt(DateTime when) async {
    writeCount++;
    deferredAt = when;
  }
}
