import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// The dimmed ambient "what the AI is chewing on" strip (D1), drawn on both
/// HOME-01 and EMPTY-01 (docs/designs/Relay Mobile.dc.html ~lines 130, 570).
///
/// Ambient status, **not** a queue row: the two-decision-type rule governs the
/// queue, not this. Deliberately a count — no per-card rows, no progress % — because
/// F4's feed carries no per-card working data. The caller hides this entirely when
/// `meta.working_count` is absent or 0, so there is no gap and no placeholder.
class WorkingStrip extends StatelessWidget {
  const WorkingStrip({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Opacity(
      opacity: 0.72, // artboard
      child: Container(
        key: const Key('working_strip'),
        padding: const EdgeInsets.all(18), // artboard 11
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(18), // artboard 11
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10, // artboard 6
                  height: 10,
                  decoration: const BoxDecoration(
                    color: RelayTheme.relayAI,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10), // artboard 6
                Text(
                  'working · $count ${count == 1 ? 'card' : 'cards'}',
                  style: const TextStyle(
                    fontSize: 16, // artboard 10
                    fontFamily: 'monospace',
                    color: RelayTheme.relayAI,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10), // artboard 6
            Text(
              'Relay AI is on it',
              style: TextStyle(
                fontSize: 19, // artboard 12
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
