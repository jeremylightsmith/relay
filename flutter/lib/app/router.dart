import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/board/board_screen.dart';
import '../features/needs_you/needs_you_screen.dart';
import '../features/settings/settings_screen.dart';
import '../widgets/main_scaffold.dart';

/// Builds the app's GoRouter. Kept as a plain function so it can be constructed
/// in tests, and exposed via [routerProvider] for non-widget navigation.
GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/needs-you',
    routes: [
      GoRoute(path: '/', redirect: (context, state) => '/needs-you'),
      ShellRoute(
        builder: (context, state, child) => MainScaffold(child: child),
        routes: [
          GoRoute(
            path: '/needs-you',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const NeedsYouScreen(),
            ),
          ),
          GoRoute(
            path: '/board',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const BoardScreen(),
            ),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => NoTransitionPage(
              key: state.pageKey,
              child: const SettingsScreen(),
            ),
          ),
        ],
      ),
    ],
  );
}

/// The app's single GoRouter instance. Non-widget code (e.g. the future push
/// handler) reads this to navigate without a BuildContext.
final routerProvider = Provider<GoRouter>((ref) => buildRouter());
