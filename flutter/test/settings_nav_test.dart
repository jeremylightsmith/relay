import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'needs_you_screen_test.dart' show FakeFeedRepository;
import 'support/fake_auth.dart';

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};

Future<void> pumpShell(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(
          () => FakeAuthController(
            const AuthState(status: AuthStatus.signedIn, user: _user),
          ),
        ),
        feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
        authTokenProvider.overrideWithValue('relayu_test'),
      ],
      child: MaterialApp.router(
        theme: RelayTheme.light,
        routerConfig: buildRouter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the Account row pushes /account over the tab bar; back returns',
    (tester) async {
      await pumpShell(tester);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings_account_row')));
      await tester.pumpAndSettle();

      // /account is outside the ShellRoute: full-screen, tab bar covered
      expect(find.widgetWithText(AppBar, 'Account'), findsOneWidget);
      expect(find.byKey(const Key('account_log_out')), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );
}
