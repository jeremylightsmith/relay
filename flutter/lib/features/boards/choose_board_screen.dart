import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'boards_controller.dart';
import 'current_board.dart';
import 'widgets/board_row.dart';

/// BOARDS-00 · "Choose a board" (RE376). A full-screen list outside the tab shell,
/// shown only when no board is remembered: first sign-in, or a remembered board
/// that was deleted or had its membership revoked. Picking a row makes that board
/// current and lands on its Needs you. A single-board user never sees this screen,
/// because BoardsController auto-selects their board and the router moves on.
class ChooseBoardScreen extends ConsumerWidget {
  const ChooseBoardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final boards = ref.watch(boardsProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choose a board',
                    key: const Key('choose_board_title'),
                    style: TextStyle(
                      fontSize: 28, // mockup text-2xl
                      fontWeight: FontWeight.w700, // font-bold
                      letterSpacing: -0.6, // tracking-tight
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You can switch any time from the title.',
                    key: const Key('choose_board_subtitle'),
                    style: TextStyle(
                      fontSize: 15, // mockup text-[13px]
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: boards.when(
                loading: () => const Center(
                  key: Key('choose_board_loading'),
                  child: CircularProgressIndicator(),
                ),
                error: (_, _) => _Message(
                  key: const Key('choose_board_error'),
                  text: "Couldn't load your boards.",
                  action: FilledButton(
                    key: const Key('choose_board_retry'),
                    onPressed: () =>
                        ref.read(boardsProvider.notifier).refresh(),
                    child: const Text('Retry'),
                  ),
                ),
                data: (list) => list.isEmpty
                    ? const _Message(
                        key: Key('choose_board_empty'),
                        text:
                            "You don't have any boards yet. Create one on the web, then come back.",
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) => BoardRow(
                          board: list[i],
                          showMeta: true,
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
                          onTap: () async {
                            await ref
                                .read(currentBoardProvider.notifier)
                                .switchTo(list[i].slug);
                            if (context.mounted) context.go('/needs-you');
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
