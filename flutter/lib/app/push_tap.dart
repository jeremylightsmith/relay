import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/boards/board_summary.dart';
import '../features/boards/boards_controller.dart';
import '../features/boards/current_board.dart';
import 'messenger.dart';
import 'router.dart';

/// Opens a tapped push (RE376 §7 · PUSH-01) — the warm and cold paths both land
/// here. A push for another board first switches the **whole app** to that board,
/// with a brief `Switched to <board>` toast, then opens the card. A push for the
/// current board just opens it. The payload is unchanged (`card_ref`,
/// `board_slug`, `kind`).
///
/// The switch happens before `router.go`, so a cold launch never reaches
/// Choose a board: by the time the redirect checks for a board, there is one.
class PushTapHandler {
  PushTapHandler(this._ref);

  final Ref _ref;

  Future<void> open(Map<String, dynamic> payload) async {
    final path = pathForPayload(payload);
    if (path == null) return;
    // pathForPayload already returned null for a payload without a board.
    final slug = payload['board_slug'] as String;

    final board = _ref.read(currentBoardProvider.notifier);
    await board.ready;
    if (_ref.read(currentBoardProvider).slug != slug) {
      final name = _boardName(slug);
      await board.switchTo(slug);
      _toast('Switched to $name');
    }
    _ref.read(routerProvider).go(path);
  }

  /// The board's name from the list when it is loaded, otherwise the slug. This
  /// never triggers a fetch, because on a cold launch auth may still be restoring.
  String _boardName(String slug) {
    if (!_ref.exists(boardsProvider)) return slug;
    for (final b in _ref.read(boardsProvider).value ?? const <BoardSummary>[]) {
      if (b.slug == slug) return b.name;
    }
    return slug;
  }

  void _toast(String text) {
    _ref
        .read(scaffoldMessengerKeyProvider)
        .currentState
        ?.showSnackBar(
          SnackBar(
            key: const Key('board_switched_toast'),
            content: Text(text),
            duration: const Duration(seconds: 2),
          ),
        );
  }
}

final pushTapHandlerProvider = Provider<PushTapHandler>(PushTapHandler.new);
