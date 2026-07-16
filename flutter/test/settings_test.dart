import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/settings/settings_screen.dart';

import 'support/fake_auth.dart';

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};

Future<void> pumpSettings(
  WidgetTester tester, {
  Map<String, dynamic> user = _user,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(
          () => FakeAuthController(
            AuthState(status: AuthStatus.signedIn, user: user),
          ),
        ),
      ],
      child: MaterialApp(theme: RelayTheme.light, home: const SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
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
    'exactly one row — Account with a chevron — and no Log out button',
    (tester) async {
      await pumpSettings(tester);

      expect(find.byKey(const Key('settings_account_row')), findsOneWidget);
      expect(find.text('Account'), findsOneWidget);
      expect(find.text('›'), findsOneWidget);
      // pin the SET-01 divergences: no Log out here, no unbacked rows, no toggles
      expect(find.text('Log out'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Notifications'), findsNothing);
      expect(find.text('Voice replies'), findsNothing);
    },
  );
}
