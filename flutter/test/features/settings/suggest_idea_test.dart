// RE397: the Settings "Suggest an idea" row opens Relay's public roadmap in the
// system browser, and only when the server sent a `feedback_url`.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/settings/external_url_launcher.dart';
import 'package:relay_mobile/features/settings/settings_screen.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

import '../../needs_you_screen_test.dart' show FakeFeedRepository;
import '../../support/fake_auth.dart';
import '../../support/fake_boards.dart';

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};
const _roadmap = 'https://relayboard.fly.dev/board/relay/public';

/// Replays one canned outcome (bool or Exception) and records each call.
class RecordingLaunch {
  RecordingLaunch(this.result);

  final Object result;
  final calls = <(Uri, LaunchMode)>[];

  Future<bool> call(Uri uri, LaunchMode mode) async {
    calls.add((uri, mode));
    if (result is bool) return result as bool;
    throw result as Exception;
  }
}

Future<void> pumpSettings(
  WidgetTester tester, {
  String? feedbackUrl = _roadmap,
  RecordingLaunch? launcher,
}) async {
  final auth = FakeAuthController(
    AuthState(
      status: AuthStatus.signedIn,
      user: _user,
      token: 'relayu_t',
      feedbackUrl: feedbackUrl,
    ),
  );
  final recorder = launcher ?? RecordingLaunch(true);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('mkt')),
        boardsRepositoryProvider.overrideWithValue(
          FakeBoardsRepository(
            boards: [makeBoard('mkt', name: 'Marketing site')],
          ),
        ),
        feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
        externalUrlLauncherProvider.overrideWithValue(recorder.call),
      ],
      child: MaterialApp(theme: RelayTheme.light, home: const SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

const _rowsCard = Key('settings_rows_card');
const _row = Key('settings_suggest_idea');
const _logOut = Key('settings_log_out');
const _failure = "Couldn't open the link";

void main() {
  testWidgets('a configured feedback URL shows the Suggest an idea row', (
    tester,
  ) async {
    await pumpSettings(tester);

    expect(find.byKey(_row), findsOneWidget);
    expect(find.text('Suggest an idea'), findsOneWidget);
    expect(
      find.text("Share or upvote ideas on Relay's public roadmap"),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
    expect(find.byKey(_logOut), findsOneWidget);
  });

  testWidgets(
    'the rows card sits between the identity block and Log out, outlined '
    'with radius 12',
    (tester) async {
      await pumpSettings(tester);

      final cardTop = tester.getTopLeft(find.byKey(_rowsCard)).dy;
      expect(
        cardTop,
        greaterThan(
          tester.getTopLeft(find.byKey(const Key('settings_email'))).dy,
        ),
      );
      expect(cardTop, lessThan(tester.getTopLeft(find.byKey(_logOut)).dy));

      final scheme = Theme.of(
        tester.element(find.byKey(_rowsCard)),
      ).colorScheme;
      final decoration =
          tester.widget<Container>(find.byKey(_rowsCard)).decoration!
              as BoxDecoration;
      expect((decoration.border! as Border).top.color, scheme.outlineVariant);
      expect(decoration.borderRadius, BorderRadius.circular(12));
    },
  );

  testWidgets(
    'tapping the row opens the roadmap in the system browser, no snackbar',
    (tester) async {
      final launcher = RecordingLaunch(true);
      await pumpSettings(tester, launcher: launcher);

      await tester.tap(find.byKey(_row));
      await tester.pumpAndSettle();

      expect(launcher.calls, [
        (Uri.parse(_roadmap), LaunchMode.externalApplication),
      ]);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('a refused launch shows the failure snackbar', (tester) async {
    await pumpSettings(tester, launcher: RecordingLaunch(false));

    await tester.tap(find.byKey(_row));
    await tester.pump();

    expect(find.text(_failure), findsOneWidget);
  });

  testWidgets('a throwing launch is caught and shows the failure snackbar', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      launcher: RecordingLaunch(PlatformException(code: 'ACTIVITY_NOT_FOUND')),
    );

    await tester.tap(find.byKey(_row));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text(_failure), findsOneWidget);
  });

  testWidgets('no feedback URL renders today\'s screen — no rows card', (
    tester,
  ) async {
    await pumpSettings(tester, feedbackUrl: null);

    expect(find.byKey(_rowsCard), findsNothing);
    expect(find.byKey(_row), findsNothing);
    expect(find.text('Suggest an idea'), findsNothing);
    expect(find.byKey(_logOut), findsOneWidget);
  });

  testWidgets('a blank feedback URL also hides the rows card', (tester) async {
    await pumpSettings(tester, feedbackUrl: '');

    expect(find.byKey(_rowsCard), findsNothing);
    expect(find.byKey(_logOut), findsOneWidget);
  });
}
