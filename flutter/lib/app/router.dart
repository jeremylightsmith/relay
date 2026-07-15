import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/auth/splash_screen.dart';
import '../features/auth/welcome_screen.dart';
import '../features/board/board_screen.dart';
import '../features/card/card_screen.dart';
import '../features/decisions/answer_screen.dart';
import '../features/decisions/reject_note_screen.dart';
import '../features/needs_you/needs_you_screen.dart';
import '../features/push/push_onboarding.dart';
import '../features/push/push_permission_screen.dart';
import '../features/push/push_service.dart';
import '../features/settings/settings_screen.dart';
import '../widgets/main_scaffold.dart';
import 'pending_deep_link.dart';

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
        // The gate (RLY-84 §1). `routerProvider`'s redirect decides *when* this
        // is the right moment — an interactive sign-in with nothing to resume —
        // and this decides *whether* iOS and the cooldown actually allow it.
        // Splitting it that way keeps the async status read out of the top-level
        // redirect, which runs on every navigation and is effectively sync.
        //
        // Route-level, so only a navigation *here* pays for it. Returning
        // /needs-you is a no-op detour: the redirect was already sending the
        // user there.
        redirect: (context, state) async {
          final gate = ProviderScope.containerOf(
            context,
          ).read(pushOnboardingProvider);
          final decision = await gate.resolve();
          return decision == PushGateDecision.prime ? null : '/needs-you';
        },
        builder: (context, state) => Consumer(
          builder: (context, ref, _) => PushPermissionScreen(
            onAllow: () async {
              await ref.read(pushServiceProvider).enable();
              if (context.mounted) context.go('/needs-you');
            },
            onSkip: () async {
              // "Not now" never invokes the OS prompt, so iOS stays notDetermined
              // — if we don't remember this ourselves we re-prime every launch,
              // which is the defect RLY-84 exists to fix.
              await ref.read(pushOnboardingProvider).deferPriming();
              if (context.mounted) context.go('/needs-you');
            },
          ),
        ),
      ),
      // The card-detail host (RLY-87). Both entry paths land here: the inbox tap and a
      // notification tap. `board` and `kind` ride as query params — `extra` would not
      // survive a cold deep link.
      GoRoute(
        path: '/cards/:ref',
        builder: (context, state) => CardScreen(
          cardRef: state.pathParameters['ref']!,
          boardSlug: state.uri.queryParameters['board'] ?? '',
          kind: state.uri.queryParameters['kind'],
          bodyBuilder: cardBodyBuilder,
        ),
      ),
      // RLY-88 · CORE-07. Sibling of /cards/:ref, not a child: it is a full-screen step, not
      // part of the host. `board` rides as a query param like `kind` does above — `extra`
      // would not survive a cold deep link.
      GoRoute(
        path: '/card/:ref/reject',
        builder: (context, state) => RejectNoteScreen(
          cardRef: state.pathParameters['ref']!,
          boardSlug: state.uri.queryParameters['board'] ?? '',
        ),
      ),
      // RLY-89 · INPUT-01. Sibling of /card/:ref, not a child: a full-screen answer
      // surface, not part of the host. No `board` query param — unlike /card/:ref/reject,
      // this screen reads its QueueItem (slug and all) from the ReviewQueue snapshot.
      GoRoute(
        path: '/card/:ref/answer',
        builder: (context, state) =>
            AnswerScreen(cardRef: state.pathParameters['ref']!),
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

/// Overrides the card screen's webview body. Null in production; tests override it
/// because flutter_inappwebview has no host-platform implementation (RLY-81), so
/// the gated router cannot otherwise be pumped through a card route.
final cardBodyBuilderProvider = Provider<WidgetBuilder?>((ref) => null);

/// The app's single GoRouter instance, **auth-gated**: a signed-out user is sent to
/// `/welcome`, and Sign in lives *under* it at `/welcome/sign-in` so go_router builds
/// the `[Welcome, SignIn]` stack itself — back (and iOS swipe-back) returns to Welcome
/// with no manual push bookkeeping, even on a cold deep-link. A signed-in user anywhere
/// in the auth stack bounces to the shell; [refreshListenable] re-runs this the moment
/// sign-in succeeds, which is why no navigation call belongs in [AuthController].
///
/// RLY-86 adds the third state: while auth is *restoring*, the destination is stashed
/// and the router parks on `/splash` — so a cold-start deep link survives the Keychain
/// read, and then survives sign-in if the session turns out to be gone.
final routerProvider = Provider<GoRouter>((ref) {
  // Status, not `signedIn`: the restoring → signedOut transition must re-run the
  // redirect too, or the app parks on the splash forever.
  final refresh = ValueNotifier<AuthStatus>(ref.read(authProvider).status);
  ref.onDispose(refresh.dispose);

  // Whether the most recent signedIn arrived via an *interactive* sign-in
  // (signingIn → signedIn) rather than a restore. AUTH-03 only primes for
  // permission after an interactive sign-in with nothing to resume — and the
  // redirect below is the only place that sees both auth and the pending
  // deep link, so it (not main.dart) is what decides. A launch-time bool in
  // main.dart can't: it answers "was this launch cold?", not "is there a card
  // to land on?", and a warm tap while signed out never touches it at all.
  var interactiveSignIn = false;
  ref.listen(authProvider, (previous, next) {
    interactiveSignIn =
        previous?.status == AuthStatus.signingIn && next.signedIn;
    refresh.value = next.status;
  });

  return buildRouter(
    refreshListenable: refresh,
    cardBodyBuilder: ref.watch(cardBodyBuilderProvider),
    extraRoutes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
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
      final auth = ref.read(authProvider);
      final pending = ref.read(pendingDeepLinkProvider);
      final loc = state.matchedLocation;
      final atAuth = loc.startsWith('/welcome');
      final atSplash = loc == '/splash';
      // GoRouter always matches its `initialLocation` first, on every cold
      // launch, push or no push — so stashing it unconditionally would make
      // `pending` non-null even with nothing to resume, indistinguishable
      // from a real deep link. It's also already the fallback below, so
      // skipping it here changes nothing about where a plain launch lands.
      final isDefaultLanding = loc == '/needs-you';

      // Still reading the Keychain: hold the destination, show the splash.
      if (auth.restoring) {
        if (atSplash) return null;
        if (!isDefaultLanding) pending.set(state.uri.toString());
        return '/splash';
      }
      if (!auth.signedIn) {
        if (atAuth) return null;
        // Never stash the splash itself — it is scaffolding, not a destination.
        if (!atSplash && !isDefaultLanding) pending.set(state.uri.toString());
        return '/welcome';
      }
      // Signed in, sitting on scaffolding → resume what the launch was actually
      // for. Nothing pending and this was an interactive sign-in: prime for
      // push permission instead (AUTH-03) — consumed once, so it doesn't fire
      // again on some later, unrelated visit to this scaffolding.
      if (atAuth || atSplash) {
        final resumed = pending.take();
        if (resumed != null) return resumed;
        if (interactiveSignIn) {
          interactiveSignIn = false;
          return '/push-permission';
        }
        return '/needs-you';
      }
      return null;
    },
  );
});

/// The route a push payload (RLY-81 §5) deep-links to. Null when the payload carries no
/// card — nothing to route to, so the tap just opens the app.
///
/// `kind` rides through so the host can pick its bottom bar without a fetch (RLY-87 §5);
/// `Relay.Push.payload/3` has always emitted it. **Accepted cost:** a *stale* push — the
/// card was `needs_input` when sent and `in_review` when tapped — carries the old kind and
/// shows the wrong bar. Harmless here (RLY-87's actions are stubbed), but **RLY-88 must
/// handle it** when the buttons start calling the API. Absent kind → no bar, rather than
/// the wrong one. This deliberately supersedes RLY-86 §8, which routed every push without
/// `kind` on the assumption RLY-87 would read the card's current state; the approved spec
/// chose the URL instead.
String? pathForPayload(Map<String, dynamic> payload) {
  final ref = payload['card_ref'] as String?;
  final slug = payload['board_slug'] as String?;
  if (ref == null || slug == null) return null;

  final kind = payload['kind'] as String?;
  final base = '/cards/$ref?board=$slug';
  return kind == null ? base : '$base&kind=$kind';
}
