import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/router.dart';
import 'app/theme.dart';
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

    // AUTH-03's permission prime is decided by routerProvider's redirect, not here:
    // it is the only place that sees both auth status and the pending deep link
    // (RLY-86 §6), so it alone can tell "interactive sign-in, nothing to resume"
    // apart from every other path that lands back on signed-in scaffolding.

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

    // Re-register the device token on every launch when push is already
    // authorized (RLY-84 §2). This is not part of the AUTH-03 decision — that
    // is the /push-permission route's own redirect, which only runs when the
    // router sends us there. It has to happen here, unconditionally: RLY-81
    // registers only on the "Allow" tap, and now that RLY-86 persists the
    // session, a restored launch never shows AUTH-03 and would otherwise
    // silently stop being registered. It is also correct on its own terms —
    // APNs tokens can change, and the backend upserts by token, so re-running
    // it is idempotent and re-points the row after an account switch.
    await ref.read(pushServiceProvider).registerIfAuthorized();
  }
}
