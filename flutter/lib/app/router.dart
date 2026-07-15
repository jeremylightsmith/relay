import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/board/board_screen.dart';
import '../features/card/card_screen.dart';
import '../features/needs_you/needs_you_screen.dart';
import '../features/push/push_permission_screen.dart';
import '../features/push/push_service.dart';
import '../features/settings/settings_screen.dart';
import '../widgets/main_scaffold.dart';

/// Builds the app's GoRouter. Kept as a plain function so tests can construct the
/// tab shell directly (ungated). Production wraps it with the auth gate via
/// [routerProvider] (redirect + the extra `/welcome` auth stack).
///
/// [cardBodyBuilder] overrides the card screen's webview body — tests pass a stub,
/// because flutter_inappwebview has no host-platform implementation (RLY-81).
GoRouter buildRouter({
  GoRouterRedirect? redirect,
  Listenable? refreshListenable,
  List<RouteBase> extraRoutes = const [],
  WidgetBuilder? cardBodyBuilder,
}) {
  return GoRouter(
    initialLocation: '/needs-you',
    redirect: redirect,
    refreshListenable: refreshListenable,
    routes: [
      GoRoute(path: '/', redirect: (context, state) => '/needs-you'),
      ...extraRoutes,
      // AUTH-03. `onAllow` is what actually asks iOS and registers the token.
      GoRoute(
        path: '/push-permission',
        builder: (context, state) => Consumer(
          builder: (context, ref, _) => PushPermissionScreen(
            onAllow: () async {
              await ref.read(pushServiceProvider).enable();
              if (context.mounted) context.go('/needs-you');
            },
            onSkip: () => context.go('/needs-you'),
          ),
        ),
      ),
      // Where a notification tap lands (RLY-81). The board slug rides as a query
      // param because the web opens a card at /board/:slug?card=:ref.
      GoRoute(
        path: '/cards/:ref',
        builder: (context, state) => CardScreen(
          cardRef: state.pathParameters['ref']!,
          boardSlug: state.uri.queryParameters['board'] ?? '',
          bodyBuilder: cardBodyBuilder,
        ),
      ),
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

/// The app's single GoRouter instance, **auth-gated**: a signed-out user is sent to
/// `/welcome`, and Sign in lives *under* it at `/welcome/sign-in` so go_router builds
/// the `[Welcome, SignIn]` stack itself — back (and iOS swipe-back) returns to Welcome
/// with no manual push bookkeeping, even on a cold deep-link. A signed-in user anywhere
/// in the auth stack bounces to the shell; [refreshListenable] re-runs this the moment
/// sign-in succeeds, which is why no navigation call belongs in [AuthController].
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<bool>(ref.read(authProvider).signedIn);
  ref.onDispose(refresh.dispose);
  ref.listen(authProvider, (_, next) => refresh.value = next.signedIn);

  return buildRouter(
    refreshListenable: refresh,
    extraRoutes: [
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
        routes: [
          GoRoute(
            path: 'sign-in',
            builder: (context, state) => const SignInScreen(),
          ),
        ],
      ),
    ],
    redirect: (context, state) {
      final signedIn = ref.read(authProvider).signedIn;
      final atAuth = state.matchedLocation.startsWith('/welcome');
      if (!signedIn) return atAuth ? null : '/welcome';
      if (atAuth) return '/needs-you';
      return null;
    },
  );
});

/// The route a push payload (RLY-81 §5) deep-links to. Null when the payload
/// carries no card — nothing to route to, so the tap just opens the app.
String? pathForPayload(Map<String, dynamic> payload) {
  final ref = payload['card_ref'] as String?;
  final slug = payload['board_slug'] as String?;
  if (ref == null || slug == null) return null;
  return '/cards/$ref?board=$slug';
}
