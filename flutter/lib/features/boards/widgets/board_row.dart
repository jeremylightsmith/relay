import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../board_summary.dart';

/// One board in the switcher sheet (SWITCH-01) and on Choose a board (BOARDS-00)
/// — the same row in both places, as card mockup "B — always in one board,
/// switch from the title" draws it: name, an amber "N needs you" badge (absent
/// at 0), a ✓ on the current board, and (Choose a board only) the meta line.
///
/// The top line ends with a 44px star tap target (RE396, card mockup "B — native
/// Switch board sheet: same order, star at far right of each row"): a neutral
/// filled star when starred, an outline star at 40% when not. Tapping it calls
/// [onToggleStar] only; tapping anywhere else calls [onTap].
///
/// Immediately left of the star sits a 44px bell (RE406, card mockup "A — bell
/// beside the star on the shared board row (Choose a board + Switch board
/// sheet)"): an outline bell when notifying, a slashed bell when muted, both at
/// 40% and never dimming the row. Tapping it calls [onToggleMute] only.
class BoardRow extends StatelessWidget {
  const BoardRow({
    super.key,
    required this.board,
    required this.onTap,
    required this.onToggleStar,
    required this.onToggleMute,
    this.current = false,
    this.showMeta = false,
  });

  final BoardSummary board;
  final VoidCallback onTap;
  final VoidCallback onToggleStar;
  final VoidCallback onToggleMute;
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
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4), // py-1 pl-3 pr-1
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8), // py-2
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
                  _MuteButton(
                    key: Key('board_row_mute_${board.slug}'),
                    muted: board.muted,
                    onPressed: onToggleMute,
                  ),
                  _StarButton(
                    key: Key('board_row_star_${board.slug}'),
                    starred: board.starred,
                    onPressed: onToggleStar,
                  ),
                ],
              ),
              if (showMeta)
                Padding(
                  // The row's 4px bottom padding + 8 keeps the meta's gap at 12.
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
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

/// The mockup's `ml-1 size-11 rounded-lg` star: a 44×44 target, icon size 20,
/// `hero-star-solid text-base-content` / `hero-star text-base-content/40`.
class _StarButton extends StatelessWidget {
  const _StarButton({
    super.key,
    required this.starred,
    required this.onPressed,
  });

  final bool starred;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(
          starred ? Icons.star : Icons.star_border,
          size: 20,
          color: starred ? onSurface : onSurface.withValues(alpha: 0.4),
          semanticLabel: starred ? 'Unstar board' : 'Star board',
        ),
      ),
    );
  }
}

/// The mockup's `ml-1 size-11 rounded-lg` bell: a 44×44 target, icon size 20,
/// `hero-bell` / `hero-bell-slash`, both `text-base-content/40`.
class _MuteButton extends StatelessWidget {
  const _MuteButton({super.key, required this.muted, required this.onPressed});

  final bool muted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: IconButton(
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(
          muted ? Icons.notifications_off_outlined : Icons.notifications_none,
          size: 20,
          color: onSurface.withValues(alpha: 0.4),
          semanticLabel: muted ? 'Unmute notifications' : 'Mute notifications',
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
