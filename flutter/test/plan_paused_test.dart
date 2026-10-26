import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/plan_paused.dart';

void main() {
  test('the plan_paused code pins HamacaWeb.PlanPaused.code/0 (RE466)', () {
    expect(planPausedCode, 'plan_paused');
    // `flutter test` runs in flutter/, so the server module is one level up.
    // This pins the cross-language contract: rename one side and this fails.
    final ex = File('../lib/hamaca_web/plan_paused.ex').readAsStringSync();
    expect(ex, contains('@code "$planPausedCode"'));
  });

  test(
    'the client copy is the read-only explanation, not the server message',
    () {
      expect(
        planPausedMessage,
        "This board is read-only because its owner's plan is paused.",
      );
    },
  );
}
