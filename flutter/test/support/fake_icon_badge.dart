import 'package:relay_mobile/features/boards/icon_badge.dart';

/// A fake [IconBadge] — no MethodChannel, no OS. Records every [set] call.
class FakeIconBadge implements IconBadge {
  /// Every count the app set the icon badge to, in order.
  final List<int> calls = [];

  @override
  Future<void> set(int count) async {
    calls.add(count);
  }
}
