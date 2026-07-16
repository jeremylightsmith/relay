import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/settings/account_screen.dart';

import 'support/fake_auth.dart';

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};

Future<FakeAuthController> pumpAccount(WidgetTester tester) async {
  final auth = FakeAuthController(
    const AuthState(status: AuthStatus.signedIn, user: _user),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(() => auth)],
      child: MaterialApp(theme: RelayTheme.light, home: const AccountScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return auth;
}

void main() {
  testWidgets('shows the identity block and the Log out button', (
    tester,
  ) async {
    await pumpAccount(tester);

    expect(find.widgetWithText(AppBar, 'Account'), findsOneWidget);
    expect(find.byKey(const Key('account_avatar')), findsOneWidget);
    expect(find.text('Dana Kim'), findsOneWidget);
    expect(find.text('dana@acme.co'), findsOneWidget);
    expect(find.byKey(const Key('account_log_out')), findsOneWidget);
  });

  testWidgets('Log out opens the SET-02 confirm with the exact copy', (
    tester,
  ) async {
    await pumpAccount(tester);

    await tester.tap(find.byKey(const Key('account_log_out')));
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
    final auth = await pumpAccount(tester);

    await tester.tap(find.byKey(const Key('account_log_out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logout_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('logout_confirm')), findsNothing);
    expect(auth.signOutCalls, 0);
    // still on Account, still signed in
    expect(find.text('Dana Kim'), findsOneWidget);
    expect(find.text('dana@acme.co'), findsOneWidget);
  });

  testWidgets('confirming calls signOut exactly once', (tester) async {
    final auth = await pumpAccount(tester);

    await tester.tap(find.byKey(const Key('account_log_out')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logout_confirm_logout')));
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.byKey(const Key('logout_confirm')), findsNothing);
  });
}
