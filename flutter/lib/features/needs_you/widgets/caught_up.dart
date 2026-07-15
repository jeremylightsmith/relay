import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// EMPTY-01's body (docs/designs/Relay Mobile.dc.html ~lines 566–569): the green
/// check circle over "You're all caught up". Pure render.
class CaughtUp extends StatelessWidget {
  const CaughtUp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      key: const Key('caught_up'),
      padding: const EdgeInsets.fromLTRB(40, 72, 40, 0), // artboard 26 / 44
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 96, // artboard 60
            height: 96,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // artboard oklch(0.97 0.02 155) — the pale wash of the done token.
              color: RelayTheme.relayDone.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(
                color: RelayTheme.relayDone,
                width: 2, // artboard 1.5
              ),
            ),
            child: const Icon(
              Icons.check,
              size: 44, // artboard 28
              color: RelayTheme.relayDone,
            ),
          ),
          const SizedBox(height: 24), // artboard 16
          Text(
            "You're all caught up",
            style: TextStyle(
              fontSize: 28, // artboard 18
              fontWeight: FontWeight.w600,
              letterSpacing: -0.6,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12), // artboard 8
          Text(
            "Relay AI is working. We'll ping you the moment it needs a decision.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20, // artboard 13
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
