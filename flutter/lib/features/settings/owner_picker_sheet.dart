import 'package:flutter/material.dart';

import 'account_deletion.dart';
import 'initials.dart';

/// RE509 · SET-03a: "New owner of `<board>`" — pick who takes over [board]
/// when the account is deleted. Candidates come in server order (longest on
/// the board first); [selectedUserId] gets the check.
///
/// Resolves to the picked candidate, or null when the sheet is dismissed —
/// the caller keeps its current choice then.
Future<OwnerCandidate?> showOwnerPickerSheet(
  BuildContext context, {
  required SharedBoard board,
  required int selectedUserId,
}) {
  return showModalBottomSheet<OwnerCandidate>(
    context: context,
    // A long member list scrolls inside the sheet instead of overflowing it
    // (see HeaderedSheet for why both flags go together).
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) =>
        _OwnerPickerSheet(board: board, selectedUserId: selectedUserId),
  );
}

/// How a candidate reads when the server has no name for them.
String candidateLabel(OwnerCandidate candidate) {
  final name = candidate.name?.trim() ?? '';
  return name.isEmpty ? 'Unnamed member' : name;
}

/// A candidate's circle avatar: their photo when the server has one, else
/// initials in `primary` on a 15% `primary` fill — the mockup's
/// `bg-primary/15 text-primary`.
class CandidateAvatar extends StatelessWidget {
  const CandidateAvatar({
    super.key,
    required this.candidate,
    required this.size,
    required this.fontSize,
  });

  final OwnerCandidate candidate;
  final double size;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = candidate.avatarUrl;
    final hasPhoto = url != null && url.isNotEmpty;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: hasPhoto
          ? Image.network(url, width: size, height: size, fit: BoxFit.cover)
          : Text(
              initialsFor(candidate.name, null),
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
    );
  }
}

class _OwnerPickerSheet extends StatelessWidget {
  const _OwnerPickerSheet({required this.board, required this.selectedUserId});

  final SharedBoard board;
  final int selectedUserId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final candidate in board.candidates) {
      if (rows.isNotEmpty) {
        rows.add(
          Divider(height: 1, thickness: 1, color: scheme.outlineVariant),
        );
      }
      rows.add(
        _CandidateRow(
          candidate: candidate,
          selected: candidate.userId == selectedUserId,
        ),
      );
    }

    return Padding(
      key: const Key('owner_picker_sheet'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'New owner of ${board.name}',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Only current members can own it. Listed longest-on-board first.',
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11), // inside the border
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: rows,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Invited people who haven't signed in yet aren't listed.",
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({required this.candidate, required this.selected});

  final OwnerCandidate candidate;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final id = candidate.userId;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.08)
          : Colors.transparent,
      child: InkWell(
        key: Key('owner_picker_option_$id'),
        onTap: () => Navigator.of(context).pop(candidate),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CandidateAvatar(candidate: candidate, size: 28, fontSize: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      candidateLabel(candidate),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: scheme.onSurface,
                      ),
                    ),
                    Text(
                      memberSinceLabel(candidate.memberSince),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Text(
                  '✓',
                  key: Key('owner_picker_check_$id'),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
