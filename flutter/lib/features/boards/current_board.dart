// RE376: the app-wide current board. Every tab is about exactly one board, and
// this is the one place that says which. Persisted through RLY-95's BoardPrefs
// (Keychain, cleared on sign-out), so a cold launch reopens it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../board/board_prefs.dart';

/// Which board the app is in. [restored] is false only until the launch-time
/// Keychain read lands — the router must not mistake "not read yet" for
/// "nothing remembered" and flash Choose a board.
class CurrentBoardState {
  const CurrentBoardState({this.slug, this.restored = false});

  final String? slug;
  final bool restored;

  /// Restored and nothing chosen: the tabs have no board to show, so the
  /// router sends the user to Choose a board.
  bool get needsChoice => restored && slug == null;
}

class CurrentBoard extends Notifier<CurrentBoardState> {
  Completer<void> _ready = Completer<void>();

  /// Set by any explicit [switchTo] / [clear]: a choice made while the launch
  /// read is still in flight (a cold push tap) must survive it landing.
  bool _touched = false;

  @override
  CurrentBoardState build() {
    _ready = Completer<void>();
    _touched = false;
    // Notifier.build() is synchronous (the AuthController pattern): hand back
    // "not restored yet" and let _restore() land the real state.
    _restore();
    return const CurrentBoardState();
  }

  BoardPrefs get _prefs => ref.read(boardPrefsProvider);

  /// Completes once the state is [CurrentBoardState.restored] — after the
  /// launch read, or the first explicit switch/clear, whichever comes first.
  Future<void> get ready => _ready.future;

  Future<void> _restore() async {
    final slug = await _prefs.readLastBoardSlug();
    if (!ref.mounted) return;
    if (!_touched) {
      state = CurrentBoardState(
        slug: (slug == null || slug.isEmpty) ? null : slug,
        restored: true,
      );
    }
    _markReady();
  }

  void _markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Make [slug] the current board app-wide and remember it for next launch.
  Future<void> switchTo(String slug) async {
    _touched = true;
    state = CurrentBoardState(slug: slug, restored: true);
    _markReady();
    await _prefs.writeLastBoardSlug(slug);
  }

  /// Forget the current board (deleted, membership revoked). The router then
  /// sends the user to Choose a board.
  Future<void> clear() async {
    _touched = true;
    state = const CurrentBoardState(restored: true);
    _markReady();
    await _prefs.clear();
  }

  /// Square the current board with the user's actual boards ([slugs], freshly
  /// loaded): a listed board stays; otherwise a sole board is auto-selected
  /// (a single-board user never sees Choose a board) and a gone one is cleared.
  Future<void> reconcile(List<String> slugs) async {
    final current = state.slug;
    if (current != null && slugs.contains(current)) return;
    if (slugs.length == 1) return switchTo(slugs.single);
    if (current != null) return clear();
  }
}

final currentBoardProvider = NotifierProvider<CurrentBoard, CurrentBoardState>(
  CurrentBoard.new,
);
