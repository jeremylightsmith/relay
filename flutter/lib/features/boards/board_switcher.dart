import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'boards_controller.dart';
import 'current_board.dart';
import 'widgets/board_row.dart';

/// SWITCH-01 · the "Switch board" sheet over whatever tab is showing (RE376).
/// Needs you's and Settings' [BoardSwitcherTitle] open it, and so does the Board
/// tab's webview through the `relayOpenBoardSwitcher` bridge.
Future<void> showBoardSwitcherSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // card mockup "B — always in one board, switch from the title": rounded-t-3xl
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const BoardSwitcherSheet(),
  );
}

class BoardSwitcherSheet extends ConsumerStatefulWidget {
  const BoardSwitcherSheet({super.key});

  @override
  ConsumerState<BoardSwitcherSheet> createState() => _BoardSwitcherSheetState();
}

class _BoardSwitcherSheetState extends ConsumerState<BoardSwitcherSheet> {
  @override
  void initState() {
    super.initState();
    // Fresh counts every time the sheet opens. Post-frame, because Riverpod
    // forbids changing provider state while the widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(boardsProvider.notifier).refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final boards = ref.watch(boardsProvider);
    final current = ref.watch(currentBoardProvider.select((s) => s.slug));

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Switch board',
              key: const Key('board_switcher_title'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: boards.when(
                data: (list) => ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) => BoardRow(
                    board: list[i],
                    current: list[i].slug == current,
                    // Star and mute in place: the sheet stays open on the same board.
                    onToggleStar: () => unawaited(
                      ref
                          .read(boardsProvider.notifier)
                          .toggleStar(list[i].slug),
                    ),
                    onToggleMute: () => unawaited(
                      ref
                          .read(boardsProvider.notifier)
                          .toggleMute(list[i].slug),
                    ),
                    onTap: () {
                      // Switch and close. No navigation, so you stay on this tab.
                      unawaited(
                        ref
                            .read(currentBoardProvider.notifier)
                            .switchTo(list[i].slug),
                      );
                      Navigator.of(context).pop();
                    },
                  ),
                ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(
                      key: Key('board_switcher_loading'),
                    ),
                  ),
                ),
                error: (_, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Couldn't load your boards.",
                      key: const Key('board_switcher_error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      key: const Key('board_switcher_retry'),
                      onPressed: () =>
                          ref.read(boardsProvider.notifier).refresh(),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The board name + `▾` that titles every tab (RE376 · INBOX-01, Settings). It
/// opens [showBoardSwitcherSheet]. Before anything knows the board's name it
/// shows [placeholder], so it never blocks the tab from rendering.
class BoardSwitcherTitle extends ConsumerWidget {
  const BoardSwitcherTitle({super.key, this.fontSize = 20});

  final double fontSize;

  static const placeholder = 'Board';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final name = ref.watch(currentBoardNameProvider) ?? placeholder;

    return InkWell(
      key: const Key('board_switcher_button'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => showBoardSwitcherSheet(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              key: const Key('board_switcher_name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.03 * fontSize, // mockup tracking-tight
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '▾',
            key: const Key('board_switcher_caret'),
            // mockup: text-sm text-base-content/50
            style: TextStyle(
              fontSize: fontSize * 0.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
