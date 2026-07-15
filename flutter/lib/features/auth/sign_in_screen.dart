import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_controller.dart';

/// F2 sign-in surface (AUTH-02). Google works end-to-end; Apple is scaffolded
/// but disabled — "Sign in with Apple" needs an Apple Developer capability and
/// won't run on the simulator, so it lands when we're on a real device.
class SignInScreen extends ConsumerWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);

    return Scaffold(
      // Pushed from Welcome — the back chevron is how you get back. The artboard
      // draws only the flow arrow, but the push is real.
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Icons.bolt, color: Colors.white, size: 30),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Relay',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Keep work moving when you\'re away from your desk.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 40),
              FilledButton.icon(
                key: const Key('sign_in_google'),
                onPressed: auth.signingIn
                    ? null
                    : () => ref.read(authProvider.notifier).signInWithGoogle(),
                icon: auth.signingIn
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(
                  auth.signingIn ? 'Signing in…' : 'Continue with Google',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('sign_in_apple'),
                onPressed:
                    null, // device-only; enabled once the Apple capability exists
                icon: const Icon(Icons.apple),
                label: const Text('Sign in with Apple (soon)'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
              ),
              if (auth.error != null) ...[
                const SizedBox(height: 20),
                Text(
                  auth.error!,
                  key: const Key('sign_in_error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 12.5,
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
