import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_controller.dart';

/// AUTH-02: the provider picker. Google everywhere; on iOS, Apple's official
/// `SignInWithAppleButton` under it (RE106) — a deliberate departure from the
/// artboard's custom slot, since App Review expects Apple's own button. Android
/// shows Google only.
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
  static const providerRadius = 11.0;

  /// Both provider buttons draw at this height: Material 3's button minimum,
  /// which is what Google renders at, and what Apple's button is told to be.
  static const providerHeight = 40.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final notifier = ref.read(authProvider.notifier);
    final signInWithGoogle = notifier.signInWithGoogle;
    final signInWithApple = notifier.signInWithApple;
    // Retry whichever provider just failed (Google when unknown).
    final retry = auth.method == SignInMethod.apple
        ? signInWithApple
        : signInWithGoogle;
    // defaultTargetPlatform, not dart:io's Platform.isIOS: widget tests can
    // override the former, and on a device they agree.
    final showApple = defaultTargetPlatform == TargetPlatform.iOS;
    final googleSpinning = auth.signingIn && auth.method != SignInMethod.apple;

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
                onPressed: auth.signingIn ? null : signInWithGoogle,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, providerHeight),
                  // Beside Apple's button, lay Google out at its drawn height
                  // (no invisible tap-target padding) so the two match and sit
                  // the artboard's 9px apart.
                  tapTargetSize: showApple
                      ? MaterialTapTargetSize.shrinkWrap
                      : null,
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
                    if (googleSpinning)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      const Icon(Icons.login, size: 16),
                    const SizedBox(width: 9),
                    Text(
                      googleSpinning ? 'Signing in…' : 'Continue with Google',
                    ),
                  ],
                ),
              ),
              if (showApple) ...[
                const SizedBox(height: 9),
                // The package's button has no disabled state, so fake one
                // while any sign-in is in flight.
                IgnorePointer(
                  ignoring: auth.signingIn,
                  child: Opacity(
                    opacity: auth.signingIn ? 0.38 : 1.0,
                    child: SignInWithAppleButton(
                      key: const Key('sign_in_apple'),
                      onPressed: signInWithApple,
                      text: 'Continue with Apple',
                      height: providerHeight,
                      style: theme.brightness == Brightness.light
                          ? SignInWithAppleButtonStyle.black
                          : SignInWithAppleButtonStyle.white,
                      borderRadius: const BorderRadius.all(
                        Radius.circular(providerRadius),
                      ),
                    ),
                  ),
                ),
              ],
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
                          onPressed: retry,
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
