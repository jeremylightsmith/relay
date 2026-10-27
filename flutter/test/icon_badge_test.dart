import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/boards/icon_badge.dart';

import 'support/fake_boards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iconBadgeCount', () {
    test('sums needs-you over unmuted boards only', () {
      final boards = [
        makeBoard('a', needsYou: 3),
        makeBoard('b', needsYou: 2),
        makeBoard('c', needsYou: 4, muted: true),
      ];

      expect(iconBadgeCount(boards), 5);
    });

    test('an empty list is 0', () {
      expect(iconBadgeCount(const []), 0);
    });

    test('only muted boards counting is 0', () {
      final boards = [makeBoard('a'), makeBoard('c', needsYou: 4, muted: true)];

      expect(iconBadgeCount(boards), 0);
    });
  });

  test('ChannelIconBadge is a no-op off iOS: no relay/push call', () async {
    const channel = MethodChannel('relay/push');
    final recorded = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      recorded.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await ChannelIconBadge().set(3);

    expect(recorded, isEmpty);
  });
}
