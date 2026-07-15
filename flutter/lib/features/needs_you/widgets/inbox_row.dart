import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../models/feed_row.dart';

/// One decision row — HOME-01 (docs/designs/Relay Mobile.dc.html ~lines 127–128).
/// Pure render: takes its data in, reports taps out.
///
/// Sizes are the artboard's px × 1.585 (the 248×536 frame is ~63% of a 393×852 device).
class InboxRow extends StatelessWidget {
  const InboxRow({
    super.key,
    required this.row,
    required this.showBoardChip,
    required this.onTap,
  });

  final FeedRow row;

  /// D3: only true when the loaded feed spans more than one board.
  final bool showBoardChip;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // The accent is a clipped child, not a Border side: BoxDecoration asserts that a
    // *non-uniform* border can't be combined with a borderRadius, and the artboard's
    // row is both radiused and left-accented.
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18), // artboard 11
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17), // inside the 1px border
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // artboard: 3px oklch(0.70 0.13 65) left accent → 5px.
              Container(
                key: Key('inbox_accent_${row.ref}'),
                width: 5,
                color: RelayTheme.relayBlocked,
              ),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: Key('inbox_row_${row.ref}'),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.all(18), // artboard 11
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              _avatar(),
                              const SizedBox(width: 10), // artboard 6
                              Text(
                                row.kindLabel,
                                style: const TextStyle(
                                  fontSize: 14, // artboard 9
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'monospace',
                                  color: RelayTheme.relayBlocked,
                                ),
                              ),
                              if (showBoardChip) ...[
                                const SizedBox(width: 10),
                                _boardChip(scheme),
                              ],
                              const Spacer(),
                              Text(
                                formatAge(row.blockedAt),
                                style: TextStyle(
                                  fontSize: 14, // artboard 9
                                  fontFamily: 'monospace',
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12), // artboard 7
                          Text(
                            row.title,
                            style: TextStyle(
                              fontSize: 20, // artboard 13
                              fontWeight: FontWeight.w500,
                              color: scheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 20px violet circle with white `AI` in the artboard → 32px here.
  Widget _avatar() => Container(
    key: Key('inbox_avatar_${row.ref}'),
    width: 32,
    height: 32,
    alignment: Alignment.center,
    decoration: const BoxDecoration(
      color: RelayTheme.relayAI,
      shape: BoxShape.circle,
    ),
    child: const Text(
      'AI',
      style: TextStyle(
        fontSize: 13, // artboard 8
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
  );

  /// D3's addition to the artboard: the board key, so two same-titled cards on
  /// different boards are tellable apart.
  Widget _boardChip(ColorScheme scheme) => Container(
    key: Key('board_chip_${row.ref}'),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      row.board.key,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        fontFamily: 'monospace',
        color: scheme.onSurfaceVariant,
      ),
    ),
  );
}
