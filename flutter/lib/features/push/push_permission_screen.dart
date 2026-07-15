import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// AUTH-03 "Enable push" — docs/designs/Relay Mobile.dc.html lines ~99–117.
///
/// A plain widget with callbacks rather than a Riverpod consumer, matching the
/// repo's structural-seam test convention (see buildRouter in app/router.dart):
/// the screen is pumpable directly, and the wiring lives at the call site.
///
/// Deferring is fine — "Not now" simply dismisses; no token is registered until
/// the user allows.
class PushPermissionScreen extends StatelessWidget {
  const PushPermissionScreen({
    super.key,
    required this.onAllow,
    required this.onSkip,
  });

  final VoidCallback onAllow;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          // mockup: padding:40px 26px
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              const Center(child: _BellIcon()),
              const SizedBox(height: 24),
              Text(
                'Let Relay reach you',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4, // mockup: letter-spacing:-0.02em
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "The AI works while you're away. Notifications are how it tells you "
                'the moment it needs a decision.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              // mockup: <div style="flex:1"></div> pushes the CTAs to the bottom
              const Spacer(),
              FilledButton(
                key: const Key('push_allow'),
                onPressed: onAllow,
                style: FilledButton.styleFrom(
                  backgroundColor: RelayTheme.relayHuman,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Allow notifications'),
              ),
              const SizedBox(height: 11),
              TextButton(
                key: const Key('push_skip'),
                onPressed: onSkip,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.all(6),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 64×64 rounded tile with a bell glyph and the amber "needs you" dot
/// (mockup line 109).
class _BellIcon extends StatelessWidget {
  const _BellIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: RelayTheme.relayHuman.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.notifications_none,
              size: 30,
              color: RelayTheme.relayHuman,
            ),
          ),
          Positioned(
            top: 14,
            right: 14,
            child: Container(
              key: const Key('push_icon_dot'),
              width: 12,
              height: 12,
              decoration: const BoxDecoration(
                color: RelayTheme.relayBlocked,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
