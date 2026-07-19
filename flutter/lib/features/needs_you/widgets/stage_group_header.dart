import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// The bar above each group of inbox rows (RLY-156): a stage-type coloured dot, the
/// top-level stage name in uppercase mono, and the group's row count.
///
/// **No artboard governs this.** `docs/designs/Relay Mobile.dc.html`'s *Needs you* screen
/// predates the grouping and shows a flat list, so this follows the board's own
/// band-header idiom (dot + uppercase mono label + count, `board_live.ex:191-205`) at
/// [InboxRow]'s scale instead. Pure render: takes its data in, draws.
class StageGroupHeader extends StatelessWidget {
  const StageGroupHeader({
    super.key,
    required this.name,
    required this.type,
    required this.count,
  });

  /// The top-level stage name. Empty for the trailing unlabelled group, which draws as
  /// `OTHER` — a bar with no name reads as a rendering bug.
  final String name;

  /// The stage's behaviour type, or null when the server didn't say.
  final String? type;

  final int count;

  /// The stable key fragment tests and the acceptance criteria address this by.
  String get _slug => name.isEmpty ? 'other' : name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      key: Key('stage_group_$_slug'),
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Container(
            key: Key('stage_group_dot_$_slug'),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: RelayTheme.stageTypeColor(type),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            name.isEmpty ? 'OTHER' : name.toUpperCase(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              fontFamily: 'monospace',
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 9),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
