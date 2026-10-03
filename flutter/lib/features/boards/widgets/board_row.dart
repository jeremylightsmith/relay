import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../board_summary.dart';

/// One board in the switcher sheet (SWITCH-01) and on Choose a board (BOARDS-00)
/// — the same row in both places, as card mockup "B — always in one board,
/// switch from the title" draws it: name, an amber "N needs you" badge (absent
/// at 0), a ✓ on the current board, and (Choose a board only) the meta line.
class BoardRow extends StatelessWidget {
  const BoardRow({
    super.key,
    required this.board,
    required this.onTap,
    this.current = false,
    this.showMeta = false,
  });

  final BoardSummary board;
  final VoidCallback onTap;
  final bool current;
  final bool showMeta;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12); // mockup rounded-xl

    return Material(
      key: Key('board_row_surface_${board.slug}'),
      // current: border-primary bg-primary/5; otherwise border-base-300.
      color: current ? scheme.primary.withValues(alpha: 0.05) : scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(
          color: current ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: InkWell(
        key: Key('board_row_${board.slug}'),
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12), // mockup p-3
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      board.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  if (board.needsYouCount > 0)
                    _NeedsYouBadge(
                      key: Key('board_row_needs_you_${board.slug}'),
                      count: board.needsYouCount,
                    ),
                  if (current)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        '✓',
                        key: Key('board_row_current_${board.slug}'),
                        style: TextStyle(fontSize: 14, color: scheme.primary),
                      ),
                    ),
                ],
              ),
              if (showMeta)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    board.metaLabel,
                    key: Key('board_row_meta_${board.slug}'),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mockup's `badge-soft badge-warning font-mono` — the same amber trio the
/// NEEDS INPUT pill uses.
class _NeedsYouBadge extends StatelessWidget {
  const _NeedsYouBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: RelayTheme.relayNeedsInputBg,
        border: Border.all(color: RelayTheme.relayNeedsInputBorder),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        '$count needs you',
        style: const TextStyle(
          fontSize: 10,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          color: RelayTheme.relayNeedsInputText,
        ),
      ),
    );
  }
}
