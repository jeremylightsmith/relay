// RE509 · SET-01: the quiet red "Delete account" button below Log out, and the
// `/settings/delete-account` route it pushes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/settings/account_deletion.dart';
import 'package:relay_mobile/features/settings/settings_screen.dart';

import '../../needs_you_screen_test.dart' show FakeFeedRepository;
import '../../support/fake_account_deletion.dart';
import '../../support/fake_auth.dart';
import '../../support/fake_boards.dart';

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};

Finder _key(String k) => find.byKey(Key(k));

/// The settings override set (see test/settings_test.dart), signed in with no
/// billing and no feedback URL, around [child].
Widget _scope({required Widget child}) => ProviderScope(
  overrides: [
    authProvider.overrideWith(
      () => FakeAuthController(
        const AuthState(
          status: AuthStatus.signedIn,
          user: _user,
          token: 'relayu_t',
        ),
      ),
    ),
    boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('mkt')),
    boardsRepositoryProvider.overrideWithValue(
      FakeBoardsRepository(boards: [makeBoard('mkt', name: 'Marketing site')]),
    ),
    feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
    accountDeletionRepositoryProvider.overrideWithValue(
      FakeAccountDeletionRepository(previews: [previewP()]),
    ),
  ],
  child: child,
);

void main() {
  testWidgets('Delete account sits below Log out, even with no ACCOUNT '
      'section (scenario 1)', (tester) async {
    await tester.pumpWidget(
      _scope(
        child: MaterialApp(
          theme: RelayTheme.light,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = _key('settings_delete_account');
    expect(button, findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('Delete account')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(button).dy,
      greaterThan(tester.getTopLeft(_key('settings_log_out')).dy),
    );
    expect(_key('settings_account_section'), findsNothing);
    // The rows card is always built (RE510); the button is never inside it.
    expect(
      find.descendant(of: _key('settings_rows_card'), matching: button),
      findsNothing,
    );
  });

  testWidgets('the button is a borderless, full-width red TextButton', (
    tester,
  ) async {
    await tester.pumpWidget(
      _scope(
        child: MaterialApp(
          theme: RelayTheme.light,
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = _key('settings_delete_account');
    expect(tester.widget(button), isA<TextButton>());
    expect(
      tester.getSize(button).width,
      tester.getSize(_key('settings_log_out')).width,
    );
    expect(
      tester.getTopLeft(button).dy -
          tester.getBottomLeft(_key('settings_log_out')).dy,
      12,
    );
    final scheme = Theme.of(tester.element(button)).colorScheme;
    final label = tester.widget<Text>(
      find.descendant(of: button, matching: find.text('Delete account')),
    );
    final style = DefaultTextStyle.of(
      tester.element(find.text('Delete account')),
    ).style.merge(label.style);
    expect(style.fontSize, 13);
    expect(style.fontWeight, FontWeight.w500);
    expect(style.color, scheme.error.withValues(alpha: 0.8));
  });

  testWidgets('tapping it pushes /settings/delete-account (scenario 2)', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: '/settings/delete-account',
          builder: (context, state) =>
              const Scaffold(body: Text('DELETE PAGE')),
        ),
      ],
    );
    await tester.pumpWidget(
      _scope(
        child: MaterialApp.router(
          theme: RelayTheme.light,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_key('settings_delete_account'));
    await tester.pumpAndSettle();

    expect(find.text('DELETE PAGE'), findsOneWidget);
  });

  group('the real router', () {
    Future<GoRouter> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final router = buildRouter();
      await tester.pumpWidget(
        _scope(
          child: MaterialApp.router(
            theme: RelayTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      router.go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(_key('settings_delete_account'));
      await tester.pumpAndSettle();
      return router;
    }

    testWidgets('serves the Delete account page full-screen', (tester) async {
      await pumpApp(tester);

      expect(_key('delete_account_page'), findsOneWidget);
      // Outside the ShellRoute: no tab bar under the page.
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Delete account'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Cancel returns to Settings', (tester) async {
      await pumpApp(tester);

      await tester.tap(_key('delete_account_cancel'));
      await tester.pumpAndSettle();

      expect(_key('delete_account_page'), findsNothing);
      expect(_key('settings_delete_account'), findsOneWidget);
    });

    testWidgets('the AppBar back button returns to Settings', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(_key('delete_account_page'), findsNothing);
      expect(_key('settings_delete_account'), findsOneWidget);
    });
  });
}
