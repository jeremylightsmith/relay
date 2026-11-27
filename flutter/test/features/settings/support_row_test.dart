// RE510: the Settings "Support & safety" row opens the server's public
// `/support` page in the in-app browser — always built, feedback URL or not.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/config.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import 'suggest_idea_test.dart' show RecordingLaunch, pumpSettings;

const _row = Key('settings_support_safety');
const _rowsCard = Key('settings_rows_card');
const _failure = "Couldn't open the link";

void main() {
  testWidgets('with no feedback URL the rows card still holds the row', (
    tester,
  ) async {
    await pumpSettings(tester, feedbackUrl: null);

    expect(find.byKey(_row), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(_row),
        matching: find.text('Support & safety'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(_rowsCard), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(_rowsCard), matching: find.byKey(_row)),
      findsOneWidget,
    );
  });

  testWidgets('the row has a shield, a trailing open-in-new and no subtitle', (
    tester,
  ) async {
    await pumpSettings(tester, feedbackUrl: null);

    final tile = tester.widget<ListTile>(find.byKey(_row));
    expect(tile.subtitle, isNull);
    expect(
      find.descendant(
        of: find.byKey(_row),
        matching: find.byIcon(Icons.shield_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(_row),
        matching: find.byIcon(Icons.open_in_new),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping the row opens /support in the in-app browser', (
    tester,
  ) async {
    final launcher = RecordingLaunch(true);
    await pumpSettings(tester, feedbackUrl: null, launcher: launcher);

    await tester.tap(find.byKey(_row));
    await tester.pumpAndSettle();

    expect(launcher.calls, [
      (Uri.parse('${AppConfig.baseUrl}/support'), LaunchMode.inAppBrowserView),
    ]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a refused launch shows the failure snackbar', (tester) async {
    await pumpSettings(
      tester,
      feedbackUrl: null,
      launcher: RecordingLaunch(false),
    );

    await tester.tap(find.byKey(_row));
    await tester.pump();

    expect(find.text(_failure), findsOneWidget);
  });

  testWidgets('a throwing launch is caught and shows the failure snackbar', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      feedbackUrl: null,
      launcher: RecordingLaunch(PlatformException(code: 'ACTIVITY_NOT_FOUND')),
    );

    await tester.tap(find.byKey(_row));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(_failure), findsOneWidget);
  });
}
