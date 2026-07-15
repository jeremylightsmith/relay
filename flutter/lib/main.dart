import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/router.dart';
import 'app/theme.dart';
import 'features/auth/auth_controller.dart';
import 'features/push/push_service.dart';

void main() => runApp(const ProviderScope(child: RelayApp()));

class RelayApp extends ConsumerStatefulWidget {
  const RelayApp({super.key});

  @override
  ConsumerState<RelayApp> createState() => _RelayAppState();
}

class _RelayAppState extends ConsumerState<RelayApp> {
  @override
  void initState() {
    super.initState();
    // Wire push *before* auth resolves (RLY-81 §12). A cold-start tap must reach
    // the router while it is still restoring, so the redirect stashes the card as
    // the pending deep link — otherwise the user watches /needs-you flash first.
    _wirePush();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    // AUTH-03's permission prime is decided by routerProvider's redirect and the
    // /push-permission route's own gate, not here: the redirect is the only place
    // that sees both auth status and the pending deep link (RLY-86 §6), so it
    // alone can tell "interactive sign-in, nothing to resume" apart from every
    // other path that lands back on signed-in scaffolding.

    // Re-register the device token whenever a session becomes live — on a
    // restore as well as an interactive sign-in (RLY-84 §2). RLY-81 registers
    // only on the AUTH-03 "Allow" tap, which used to be reached on every launch
    // because F2 never persisted the session. Now that RLY-86 restores it, a
    // returning user never sees AUTH-03 and would silently stop being
    // registered. It is also right on its own terms: APNs tokens can change, and
    // the backend upserts by token, so re-running is idempotent and re-points
    // the row after an account switch.
    //
    // Keyed on the signedOut→signedIn edge rather than done in _wirePush: that
    // runs before auth resolves (see initState), so registering there would race
    // the Keychain read and POST with no session cookie.
    ref.listen(authProvider, (previous, next) {
      if (next.signedIn && !(previous?.signedIn ?? false)) {
        ref.read(pushServiceProvider).registerIfAuthorized();
      }
    });

    return MaterialApp.router(
      title: 'Relay',
      theme: RelayTheme.light,
      darkTheme: RelayTheme.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }

  Future<void> _wirePush() async {
    final router = ref.read(routerProvider);
    // The shared singleton — never `IosPushPlatform()` here: a second instance
    // would re-install the `relay/push` MethodCallHandler and steal taps.
    final platform = ref.read(pushPlatformProvider);

    // Warm: a tap while the app is running (foreground or background).
    platform.onNotificationTap((payload) {
      final path = pathForPayload(payload);
      if (path != null) router.go(path);
    });

    // Cold: the app was launched *by* a tap. Fire it at the router now, even if auth
    // is still restoring — the redirect holds it until there is somewhere to land.
    final cold = await platform.initialNotification();
    final coldPath = cold == null ? null : pathForPayload(cold);
    if (coldPath != null) router.go(coldPath);
  }
}
