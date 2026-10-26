import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';

/// AUTH-01: the signed-out root. A brand splash whose only job is "show what
/// Hamaca is, go to sign-in" — deliberately auth-unaware, since the router's
/// gate guarantees it is only ever reachable while signed out.
///
/// Matches `docs/designs/Relay Mobile.dc.html` artboard AUTH-01 (lines ~54–70),
/// minus its "Create account" button (signing in with Google *is* signing up),
/// with RE479's card mockup "First run" for the Hamaca mark and headline.
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

  /// The Hamaca colour mark, a copy of
  /// `docs/brand/exports/brand/mark-color-1024.png`.
  static const markAsset = 'assets/branding/hamaca_mark.png';

  static const _markSize = 112.0; // mockup `w-28`
  // The mark's artwork is padded on its canvas, so it hangs 12px into the
  // 26px inset to line its drawing up with the text edge.
  static const _markOffset = -12.0; // mockup `-ml-3`
  static const _markGap = 20.0; // mockup `mb-5`

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
                  child: Transform.translate(
                    offset: const Offset(_markOffset, 0),
                    child: Image.asset(
                      markAsset,
                      key: const Key('welcome_mark'),
                      width: _markSize,
                      height: _markSize,
                    ),
                  ),
                ),
                const SizedBox(height: _markGap),
                const Text(
                  'Welcome to hammock driven development.',
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
                  'One board, one thread. Hamaca keeps the handoff clear.',
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
