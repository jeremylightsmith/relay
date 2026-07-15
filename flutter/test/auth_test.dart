import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/main.dart';

import 'support/fake_auth.dart';

Future<void> pumpApp(WidgetTester tester, AuthState seed) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [authProvider.overrideWith(() => FakeAuthController(seed))],
      child: const RelayApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a signed-out app is gated to Welcome; the shell is unreachable',
    (tester) async {
      await pumpApp(tester, const AuthState());

      expect(find.byKey(const Key('welcome_screen')), findsOneWidget);

      // The tab shell is NOT reachable until signed in.
      expect(find.text('Arriving soon'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
    },
  );

  testWidgets('a signed-in app boots to the shell, not the auth stack', (
    tester,
  ) async {
    await pumpApp(tester, const AuthState(user: {'email': 'dana@acme.co'}));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const Key('welcome_screen')), findsNothing);
    expect(find.byKey(const Key('sign_in_google')), findsNothing);
  });
}
