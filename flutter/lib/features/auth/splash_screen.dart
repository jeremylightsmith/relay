import 'package:flutter/material.dart';

/// The restore hold (RLY-86 §7): on screen only for a Keychain read plus one
/// `/me` round-trip.
///
/// It exists so go_router stays alive *holding the deep link* while auth resolves.
/// Gating `MaterialApp.router` on auth instead would defer building the router
/// past the cold-start push navigation, and the tap would be lost.
///
/// No artboard governs this surface (AUTH-01 "Welcome" is a sign-in screen, not a
/// restore state), so it is deliberately minimal: the wordmark on the theme
/// background.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('splash_screen'),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Relay',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}
