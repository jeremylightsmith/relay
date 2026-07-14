import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/board/board_screen.dart';
import '../features/needs_you/needs_you_screen.dart';
import '../features/settings/settings_screen.dart';
import '../widgets/main_scaffold.dart';

/// Builds the app's GoRouter. Kept as a plain function so tests can construct the
/// tab shell directly (ungated). Production wraps it with the auth gate via
/// [routerProvider] (redirect + extra `/sign-in` route).
GoRouter buildRouter({
  GoRouterRedirect? redirect,
  Listenable? refreshListenable,
  List<RouteBase> extraRoutes = const [],
}) {
  return GoRouter(
    initialLocation: '/needs-you',
    redirect: redirect,
    refreshListenable: refreshListenable,
    routes: [
      GoRoute(path: '/', redirect: (context, state) => '/needs-you'),
      ...extraRoutes,
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

/// The app's single GoRouter instance, **auth-gated**: an unauthenticated user is
/// redirected to `/sign-in`; a signed-in user at `/sign-in` bounces to the shell.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<bool>(ref.read(authProvider).signedIn);
  ref.onDispose(refresh.dispose);
  ref.listen(authProvider, (_, next) => refresh.value = next.signedIn);

  return buildRouter(
    refreshListenable: refresh,
    extraRoutes: [
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
    ],
    redirect: (context, state) {
      final signedIn = ref.read(authProvider).signedIn;
      final atSignIn = state.matchedLocation == '/sign-in';
      if (!signedIn) return atSignIn ? null : '/sign-in';
      if (atSignIn) return '/needs-you';
      return null;
    },
  );
});
