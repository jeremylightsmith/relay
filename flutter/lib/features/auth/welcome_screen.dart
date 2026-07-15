import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';

/// AUTH-01: the signed-out root. A brand splash whose only job is "show what
/// Relay is, go to sign-in" — deliberately auth-unaware, since the router's gate
/// guarantees it is only ever reachable while signed out.
///
/// Matches `docs/designs/Relay Mobile.dc.html` artboard AUTH-01 (lines ~54–70),
/// minus its "Create account" button: signing in with Google *is* signing up.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  /// The brand gradient, held in *both* themes — this is a splash, not a themed
  /// surface. CSS `linear-gradient(165deg, …)` points along (sin165°, −cos165°)
  /// = (0.26, 0.97) in Flutter's y-down Alignment space.
  static const gradient = LinearGradient(
    begin: Alignment(-0.26, -0.97),
    end: Alignment(0.26, 0.97),
    colors: [Color(0xFF23375C), Color(0xFF0D1624)],
  );

  static const _headlineInk = Color(0xFFFCFCFC); // oklch(0.99 0 0)
  static const _subheadInk = Color(0xFFCAD1DF); // oklch(0.86 0.02 262)

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('welcome_screen'),
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: gradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 64, 26, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 52,
                    height: 52,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: RelayTheme.relayHumanLight,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.circle,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 26),
                const Text(
                  'Pass work between people and AI.',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.78, // -0.03em at 26px
                    height: 1.12,
                    color: _headlineInk,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'One board, one thread. Relay keeps the handoff clear.',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: _subheadInk,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('welcome_sign_in'),
                  onPressed: () => context.go('/welcome/sign-in'),
                  style: FilledButton.styleFrom(
                    backgroundColor: RelayTheme.relayHumanLight,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
