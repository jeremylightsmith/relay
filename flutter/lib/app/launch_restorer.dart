// RE452: a cold launch reopens the remembered place. Silent when it still
// exists; one level up, with a toast saying why, when the card or stage is gone.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../api/api_client.dart';
import '../features/board/board_screen.dart';
import '../features/board/last_place.dart';
import '../features/boards/current_board.dart';
import 'messenger.dart';
import 'router.dart';
import 'tabs.dart';

/// Where a cold launch goes, from the remembered [LastPlace].
sealed class LaunchDestination {
  const LaunchDestination();
}

/// Straight to [location] — a tab, or the Board tab's stage page.
final class RouteTo extends LaunchDestination {
  const RouteTo(this.location);

  final String location;
}

/// A remembered Board-tab card: verify it still exists before reopening it
/// ([LaunchRestorer.resolveCard]).
final class ResolveCard extends LaunchDestination {
  const ResolveCard(this.place);

  final LastPlace place;
}

/// Turns the launch's remembered place into a destination, and resolves a
/// remembered card against the API. The router's redirect drives it: it takes
/// the destination once, and holds the splash while [resolving].
class LaunchRestorer {
  LaunchRestorer(this._ref);

  final Ref _ref;

  /// How long the card check may take before the card opens unverified.
  static const verifyTimeout = Duration(seconds: 3);

  /// Every restore fallback toast — card archived, deleted, stage gone.
  static const toastKey = Key('restore_toast');

  /// The Board tab, on [stageId]'s page when given.
  static String boardLocation(int? stageId) => stageId == null
      ? AppTab.board.path
      : '${AppTab.board.path}?stage=$stageId';

  bool _resolving = false;

  /// The restored stage a `relayStageMissing` may toast about, once.
  int? _armedStageId;
  String? _armedStageName;

  /// A card toast already explained this launch's fallback; a stage toast on
  /// top would be a second one for the same restore.
  bool _cardToasted = false;

  /// True while [resolveCard] runs — the redirect holds the splash.
  bool get resolving => _resolving;

  /// The launch destination — once; null when nothing was remembered or it
  /// was already taken. A Board-tab destination arms the stage-missing toast.
  LaunchDestination? takeDestination() {
    final place = _ref.read(lastPlaceProvider.notifier).takeLaunchPlace();
    if (place == null) return null;
    if (place.tab != AppTab.board) return RouteTo(place.tab.path);

    _armedStageId = place.stageId;
    _armedStageName = place.stageName;
    if (place.cardRef == null) return RouteTo(boardLocation(place.stageId));
    return ResolveCard(place);
  }

  /// Checks the remembered card and lands on it, or one level up. Does nothing
  /// once the router has left the splash: a push tap (or any navigation) beat
  /// the restore.
  Future<void> resolveCard(LastPlace place) async {
    _resolving = true;
    final ref = place.cardRef!;
    final String? slug;
    final _CardCheck check;
    try {
      await _ref.read(currentBoardProvider.notifier).ready;
      slug = _ref.read(currentBoardProvider).slug;
      check = slug == null ? const _Unverified() : await _check(ref, slug);
    } finally {
      _resolving = false;
    }

    final router = _ref.read(routerProvider);
    if (router.routerDelegate.currentConfiguration.uri.path != splashLocation) {
      return;
    }
    // No board after all (cleared mid-check): the Board tab's own redirect
    // takes it from there, to Choose a board.
    if (slug == null) return router.go(boardLocation(place.stageId));

    switch (check) {
      case _Live(:final stageId, :final status):
        await _goThenPush(router, boardLocation(stageId), {
          'ref': ref,
          'board': slug,
          'kind': status,
        });
      case _Archived(:final stageId):
        router.go(boardLocation(stageId));
        _cardToast('$ref was archived');
      case _Deleted():
        router.go(boardLocation(place.stageId));
        _cardToast('$ref was deleted');
      case _Unverified():
        await _goThenPush(router, boardLocation(place.stageId), {
          'ref': ref,
          'board': slug,
        });
    }
  }

  /// The stage-missing toast's text for [stageId] — only for the stage this
  /// launch restored, only when no card toast already showed, and only once.
  String? stageMissingMessage(int stageId) {
    final armedId = _armedStageId;
    final name = _armedStageName;
    disarmStage();
    if (armedId != stageId || name == null || _cardToasted) return null;
    return 'The $name stage no longer exists';
  }

  /// Drops the armed stage toast — the board it was restored for was left.
  void disarmStage() {
    _armedStageId = null;
    _armedStageName = null;
  }

  Future<_CardCheck> _check(String ref, String slug) async {
    try {
      final body = await _ref
          .read(apiClientProvider)
          .getJson('/api/all/cards/$ref?board=$slug')
          .timeout(verifyTimeout);
      final data = body is Map ? body['data'] : null;
      if (data is! Map) return const _Unverified();
      final archived = data['archived'];
      final stageId = data['stage_id'];
      if (archived is! bool || stageId is! int) return const _Unverified();
      if (archived) return _Archived(stageId);
      final status = data['status'];
      return _Live(stageId, status is String ? status : null);
    } on ApiException catch (e) {
      return e.statusCode == 404 ? const _Deleted() : const _Unverified();
    } on TimeoutException {
      return const _Unverified();
    }
  }

  /// `go` to the board, then push the card on top of it. The push has to wait
  /// for the `go` to land: GoRouter pushes onto the delegate's *current*
  /// configuration, which until then is still the splash.
  Future<void> _goThenPush(
    GoRouter router,
    String boardLoc,
    Map<String, String?> tap,
  ) async {
    final delegate = router.routerDelegate;
    final landed = Completer<void>();
    void listener() {
      if (!landed.isCompleted) landed.complete();
    }

    delegate.addListener(listener);
    router.go(boardLoc);
    try {
      await landed.future;
    } finally {
      delegate.removeListener(listener);
    }
    final path = BoardScreen.cardPathForTap(tap);
    // Still on the Board tab: nothing else navigated while the `go` landed.
    final onBoard = delegate.currentConfiguration.uri.path == AppTab.board.path;
    if (path != null && onBoard) router.push(path);
  }

  void _cardToast(String text) {
    _cardToasted = true;
    showToast(_ref.read(scaffoldMessengerKeyProvider), text, key: toastKey);
    unawaited(_ref.read(lastPlaceProvider.notifier).forgetCard());
  }
}

/// What the card check found.
sealed class _CardCheck {
  const _CardCheck();
}

final class _Live extends _CardCheck {
  const _Live(this.stageId, this.status);

  final int stageId;
  final String? status;
}

final class _Archived extends _CardCheck {
  const _Archived(this.stageId);

  final int stageId;
}

final class _Deleted extends _CardCheck {
  const _Deleted();
}

/// Timed out, unreachable, any other error, or a body we can't read: open the
/// card anyway, without a kind.
final class _Unverified extends _CardCheck {
  const _Unverified();
}

final launchRestorerProvider = Provider<LaunchRestorer>((ref) {
  final restorer = LaunchRestorer(ref);
  // A board change disarms the stage toast: stage ids are global, so the
  // restored id is "missing" on any other board without anything being gone.
  // The launch read (null → slug) is not a change of board.
  ref.listen(currentBoardProvider.select((s) => s.slug), (prev, next) {
    if (prev != null && prev != next) restorer.disarmStage();
  });
  return restorer;
});
