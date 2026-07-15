import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    // Notification tap → the card (RLY-81 §12). Handles both cold-start (the app
    // was launched from a notification) and warm (foreground/background) delivery.
    ref.listen(authProvider, (previous, next) {
      if (previous?.signedIn != true && next.signedIn) {
        _wirePush(router);
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

  Future<void> _wirePush(GoRouter router) async {
    // The shared singleton — never `IosPushPlatform()` here: a second instance
    // would re-install the `relay/push` MethodCallHandler and steal taps.
    final platform = ref.read(pushPlatformProvider);

    // Warm: a tap while the app is running (foreground or background).
    platform.onNotificationTap((payload) {
      final path = pathForPayload(payload);
      if (path != null) router.go(path);
    });

    // Cold: the app was launched *by* a tap — go straight to that card.
    final cold = await platform.initialNotification();
    final coldPath = cold == null ? null : pathForPayload(cold);
    if (coldPath != null) {
      router.go(coldPath);
    } else {
      // Otherwise prime for permission (AUTH-03). Skipping is free.
      router.go('/push-permission');
    }
  }
}
