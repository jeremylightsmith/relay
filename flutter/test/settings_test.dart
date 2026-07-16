import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/settings/settings_screen.dart';

import 'support/fake_auth.dart';

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};

Future<FakeAuthController> pumpSettings(
  WidgetTester tester, {
  Map<String, dynamic> user = _user,
}) async {
  final auth = FakeAuthController(
    AuthState(status: AuthStatus.signedIn, user: user),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(() => auth)],
      child: MaterialApp(theme: RelayTheme.light, home: const SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  testWidgets('renders the identity block: initials, name, monospace email', (
    tester,
  ) async {
    await pumpSettings(tester);

    expect(find.byKey(const Key('settings_avatar')), findsOneWidget);
    expect(find.text('DK'), findsOneWidget);
    expect(find.byKey(const Key('settings_name')), findsOneWidget);
    expect(find.text('Dana Kim'), findsOneWidget);
    expect(find.byKey(const Key('settings_email')), findsOneWidget);
    expect(find.text('dana@acme.co'), findsOneWidget);
  });

  testWidgets(
    'renders the photo instead of initials when avatar_url is present',
    (tester) async {
      await pumpSettings(
        tester,
        user: {..._user, 'avatar_url': 'https://lh3.example.com/p.png'},
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('settings_avatar')),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.text('DK'), findsNothing);
      // flutter_test's HttpClient answers every request with a 400; the load
      // failure is expected here (E5: no error handling) and not under test.
      tester.takeException();
    },
  );

  testWidgets('keeps the AppBar title the shell test asserts on', (
    tester,
  ) async {
    await pumpSettings(tester);
    expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
  });

  testWidgets(
    'a Log out button below the identity block — no Account row, no toggles',
    (tester) async {
      await pumpSettings(tester);

      expect(find.byKey(const Key('settings_log_out')), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Log out'), findsOneWidget);
      // pin the SET-01 divergence: no rows card at all — Account was cut at
      // Review, Notifications / Voice replies still await SET-03 / RLY-99
      expect(find.byKey(const Key('settings_account_row')), findsNothing);
      expect(find.text('Account'), findsNothing);
      expect(find.text('›'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Notifications'), findsNothing);
      expect(find.text('Voice replies'), findsNothing);
    },
  );

  testWidgets('Log out opens the SET-02 confirm with the exact copy', (
    tester,
  ) async {
    await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settings_log_out')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('logout_confirm')), findsOneWidget);
    expect(find.text('Log out of Relay?'), findsOneWidget);
    expect(
      find.text("You'll stop receiving notifications until you sign back in."),
      findsOneWidget,
    );
    expect(find.byKey(const Key('logout_confirm_logout')), findsOneWidget);
    expect(find.byKey(const Key('logout_confirm_cancel')), findsOneWidget);
  });

  testWidgets('Cancel dismisses without signing out', (tester) async {
    final auth = await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settings_log_out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logout_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('logout_confirm')), findsNothing);
    expect(auth.signOutCalls, 0);
    // still on Settings, still signed in
    expect(find.text('Dana Kim'), findsOneWidget);
    expect(find.text('dana@acme.co'), findsOneWidget);
  });

  testWidgets('confirming calls signOut exactly once', (tester) async {
    final auth = await pumpSettings(tester);

    await tester.tap(find.byKey(const Key('settings_log_out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logout_confirm_logout')));
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.byKey(const Key('logout_confirm')), findsNothing);
  });
}
