// RE509 · SET-03a: the per-board "New owner of …" bottom sheet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_account_deletion.dart';

Finder _key(String k) => find.byKey(Key(k));

Future<void> _openPicker(WidgetTester tester) async {
  await pumpDeleteAccountPage(
    tester,
    repo: FakeAccountDeletionRepository(previews: [previewP()]),
  );
  await tester.tap(_key('delete_account_owner_alpha'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists the candidates oldest first, current choice checked', (
    tester,
  ) async {
    await _openPicker(tester);

    final sheet = _key('owner_picker_sheet');
    expect(sheet, findsOneWidget);
    expect(
      find.descendant(
        of: sheet,
        matching: find.text('New owner of Relay Engineering'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(
          'Only current members can own it. Listed longest-on-board first.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(_key('owner_picker_option_12')).dy,
      lessThan(tester.getTopLeft(_key('owner_picker_option_13')).dy),
    );
    expect(
      find.descendant(
        of: _key('owner_picker_option_12'),
        matching: find.text('member since Mar 2026'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('owner_picker_option_13'),
        matching: find.text('member since Jun 2026'),
      ),
      findsOneWidget,
    );
    expect(_key('owner_picker_check_12'), findsOneWidget);
    expect(_key('owner_picker_check_13'), findsNothing);
    expect(
      find.descendant(
        of: sheet,
        matching: find.text(
          "Invited people who haven't signed in yet aren't listed.",
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking a candidate closes the sheet and updates the chip', (
    tester,
  ) async {
    await _openPicker(tester);

    await tester.tap(_key('owner_picker_option_13'));
    await tester.pumpAndSettle();

    expect(_key('owner_picker_sheet'), findsNothing);
    expect(
      find.descendant(
        of: _key('delete_account_owner_alpha'),
        matching: find.text('Kenji Ota'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the sheet checks the board\'s current choice when reopened', (
    tester,
  ) async {
    await _openPicker(tester);
    await tester.tap(_key('owner_picker_option_13'));
    await tester.pumpAndSettle();

    await tester.tap(_key('delete_account_owner_alpha'));
    await tester.pumpAndSettle();

    expect(_key('owner_picker_check_13'), findsOneWidget);
    expect(_key('owner_picker_check_12'), findsNothing);
  });

  testWidgets('dismissing the sheet keeps the current choice', (tester) async {
    await _openPicker(tester);

    // Tap the scrim above the sheet.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(_key('owner_picker_sheet'), findsNothing);
    expect(
      find.descendant(
        of: _key('delete_account_owner_alpha'),
        matching: find.text('Ana Ruiz'),
      ),
      findsOneWidget,
    );
  });
}
