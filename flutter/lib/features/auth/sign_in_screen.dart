import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// AUTH-02: the provider picker. Google works end-to-end; Apple holds RLY-106's
/// slot, disabled — "Sign in with Apple" needs an Apple Developer capability and
/// won't run on the simulator.
///
/// Matches `docs/designs/Relay Mobile.dc.html` artboard AUTH-02 (lines ~75–95)
/// selectively: its GitHub button, "or" divider, email/password fields and
/// "Forgot password?" are dropped, because `upsert_user_from_provider` is
/// provider-only — shipping four dead controls is worse than not drawing them.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  /// AUTH-02 pins these. The provider buttons are brand chrome rather than
  /// themed surfaces, so they carry their own fills in both themes.
  static const titleInk = Color(0xFF141B24); // oklch(0.22 0.02 255)
  static const googleBorder = Color(0xFFD5D8DB); // oklch(0.88 0.006 255)
  static const googleLabel = Color(0xFF272E38); // oklch(0.30 0.02 255)
  static const appleFill = Color(0xFF13161B); // oklch(0.20 0.01 260)
  static const providerRadius = 11.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    void signIn() => ref.read(authProvider.notifier).signInWithGoogle();

    final providerShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(providerRadius),
    );
    const providerLabel = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
    );

    return Scaffold(
      // The artboard draws only the flow arrow, but this screen is pushed from
      // Welcome — the back chevron is how you get back.
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sign in',
                textAlign: TextAlign.left,
                style: TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.575, // -0.025em at 23px
                  // #141B24 is the artboard's light-mode ink; dark mode follows
                  // the theme so the title stays readable.
                  color: theme.brightness == Brightness.light
                      ? titleInk
                      : scheme.onSurface,
                ),
              ),
              const SizedBox(height: 22),
              OutlinedButton(
                key: const Key('sign_in_google'),
                onPressed: auth.signingIn ? null : signIn,
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: googleLabel,
                  side: const BorderSide(color: googleBorder),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: providerShape,
                  textStyle: providerLabel,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (auth.signingIn)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.login, size: 16),
                    const SizedBox(width: 9),
                    Text(
                      auth.signingIn ? 'Signing in…' : 'Continue with Google',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 9),
              FilledButton(
                key: const Key('sign_in_apple'),
                onPressed: null, // RLY-106
                style: FilledButton.styleFrom(
                  backgroundColor: appleFill,
                  // Keep the artboard's dark slot rather than letting Flutter's
                  // default disabled fill grey it away entirely.
                  disabledBackgroundColor: appleFill.withValues(alpha: 0.38),
                  disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: providerShape,
                  textStyle: providerLabel,
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.apple, size: 16),
                    SizedBox(width: 9),
                    Text('Sign in with Apple (soon)'),
                  ],
                ),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 16),
                Container(
                  key: const Key('sign_in_error'),
                  padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: BorderRadius.circular(providerRadius),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.error!,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const Key('sign_in_retry'),
                          onPressed: signIn,
                          child: const Text('Try again'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
