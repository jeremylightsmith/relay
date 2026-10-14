import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/embedded_webview.dart';
import '../../app/launch_restorer.dart';
import '../../app/messenger.dart';
import '../../app/tabs.dart';
import '../../config.dart';
import '../boards/board_switcher.dart';
import '../boards/current_board.dart';
import '../card/card_nav_context.dart';
import '../card/card_screen.dart';
import 'last_place.dart';
import 'new_card_sheet.dart';

/// The Board tab: the **embedded chromeless LiveView board** (RLY-94 · BOARD-01) for
/// the app-wide **current board** (RE376).
///
/// The board is native state ([currentBoardProvider]), not something the webview
/// remembers. The tab loads `/board/<current>?embed=1` and remounts (that is, reloads)
/// when the current board changes. The embedded header's `<board> ▾` title bridges
/// out (`relayOpenBoardSwitcher`) to the same native Switch-board sheet the other
/// tabs use. If the board fails to load (main-frame HTTP ≥ 400: deleted board or
/// revoked membership), it is forgotten and the app goes to Choose a board.
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key, this.bodyBuilder, this.stageId});

  /// Overrides the webview body — same test seam as CardScreen.bodyBuilder:
  /// flutter_inappwebview has no host-platform implementation (RLY-81), so
  /// `flutter test` injects a stub. Null means the real webview.
  final WidgetBuilder? bodyBuilder;

  /// The stage page to open on (RE452, `/board?stage=`), or null for the first.
  /// Only the initial URL carries it: the webview stays keyed by board alone, so
  /// a different stage never remounts (reloads) the board.
  final int? stageId;

  /// The JS bridge the embedded header's board title calls (board_pager.js).
  static const openSwitcherHandler = 'relayOpenBoardSwitcher';

  /// The JS bridge the pager calls when the showing stage page changes
  /// (board_pager.js, RE452): `{board, stage_id, stage_name}`.
  static const stageChangedHandler = 'relayStageChanged';

  /// The JS bridge the pager calls, once, when `?stage=` is not on the board
  /// (board_pager.js, RE452): `{stage_id}`.
  static const stageMissingHandler = 'relayStageMissing';

  /// The window event the pager listens for to re-show a stage page
  /// (board_pager.js, RE452): `{detail: {stage_id}}`.
  static const showStageEvent = 'relay:show-stage';

  /// The script that asks the loaded board to show [stageId]'s page.
  static String showStageScript(int stageId) =>
      'window.dispatchEvent(new CustomEvent("$showStageEvent", '
      '{detail: {stage_id: $stageId}}));';

  /// Whether the Board tab is the route on screen — not covered by a pushed
  /// card ([LastPlaceTracker.topLocation] sees through the push).
  static bool isOnTop(RouteMatchList config) =>
      LastPlaceTracker.topLocation(config).path == AppTab.board.path;

  /// Records a `relayStageChanged` payload as the Board tab's stage — unless it
  /// is for another board (a stale page) or lacks a usable id or name. `ref` is
  /// read at call time, so a board switch is never raced by a captured slug.
  static void onStageChanged(WidgetRef ref, Map<dynamic, dynamic> payload) {
    final stageId = _stageIdOf(payload);
    final stageName = payload['stage_name'];
    if (stageId == null || stageName is! String || stageName.isEmpty) return;
    final slug = ref.read(currentBoardProvider).slug;
    if (slug == null || payload['board'] != slug) return;
    ref.read(lastPlaceProvider.notifier).recordStage(stageId, stageName);
  }

  /// Toasts a `relayStageMissing` payload — only for the stage this launch
  /// restored, once, and not after a card toast ([LaunchRestorer]). An
  /// in-session `?stage=` never toasts.
  static void onStageMissing(WidgetRef ref, Map<dynamic, dynamic> payload) {
    final stageId = _stageIdOf(payload);
    if (stageId == null) return;
    final message = ref
        .read(launchRestorerProvider)
        .stageMissingMessage(stageId);
    if (message == null) return;
    showToast(
      ref.read(scaffoldMessengerKeyProvider),
      message,
      key: LaunchRestorer.toastKey,
    );
  }

  /// A bridge payload's `stage_id`: an int, or a numeric string.
  static int? _stageIdOf(Map<dynamic, dynamic> payload) {
    final rawId = payload['stage_id'];
    return rawId is int
        ? rawId
        : rawId is String
        ? int.tryParse(rawId)
        : null;
  }

  /// The Board tab's URL: [slug], embedded, opening on [stageId] when given.
  static String boardUrl({
    String? baseUrl,
    required String slug,
    int? stageId,
  }) {
    final base = baseUrl ?? AppConfig.baseUrl;
    final stage = stageId == null ? '' : '&stage=$stageId';
    return '$base/board/$slug?embed=1$stage';
  }

  /// The board slug in a visited path, or null. Matches exactly `/board/<slug>`
  /// — `/boards`, `/board/<slug>/settings`, and card paths never rebind the tab.
  static String? slugFromPath(String path) {
    final match = RegExp(r'^/board/([a-z0-9-]+)$').firstMatch(path);
    return match?.group(1);
  }

  /// The native route for a `relayCardTap` payload (`{ref, board, kind}`) — the
  /// board-tap sibling of pathForPayload (app/router.dart). Null when the payload
  /// carries no ref: nothing to route to.
  static String? cardPathForTap(Map<dynamic, dynamic> payload) {
    final ref = payload['ref'] as String?;
    if (ref == null || ref.isEmpty) return null;
    final board = payload['board'] as String? ?? '';
    final kind = payload['kind'] as String?;
    final kindParam = kind == null ? '' : '&kind=$kind';
    return '/cards/$ref?board=$board$kindParam'
        '&back=${Uri.encodeQueryComponent(CardScreen.backFromBoard)}';
  }

  /// The ‹ › navigation context for a `relayCardTap` payload (RLY-234): the tapped
  /// column's ordered `cards: [{ref, kind}]` (emitted by board_live's card-tap bridge),
  /// as a [CardNavContext] seeked to the tapped ref. Null when the payload carries no
  /// column (a build/browser fallback with no `cards`) — ‹ › are then inert.
  static CardNavContext? navContextForTap(Map<dynamic, dynamic> payload) {
    final ref = payload['ref'] as String?;
    if (ref == null || ref.isEmpty) return null;
    final board = payload['board'] as String? ?? '';
    final raw = payload['cards'];
    if (raw is! List) return null;

    final items = <CardNavItem>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final r = entry['ref'] as String?;
      if (r == null || r.isEmpty) continue;
      items.add(
        CardNavItem(ref: r, boardSlug: board, kind: entry['kind'] as String?),
      );
    }
    return CardNavContext.seed(items: items, currentRef: ref);
  }

  @override
  ConsumerState<BoardScreen> createState() => BoardScreenState();
}

/// Decides, for a board webview, which `relayStageChanged` reports to keep and
/// which stage page to re-show when the board is revealed (RE452).
///
/// A card restore loads the board UNDER the pushed card: its one-shot
/// `?stage=` scroll and its first page reports run there, with no real layout,
/// and land on an arbitrary page. So reports while hidden are dropped, and on
/// each reveal the page the user last saw on screen — else the requested one —
/// is shown again (a no-op scroll when nothing drifted).
class BoardStageGate {
  BoardStageGate({required this.requestedStageId});

  /// The `?stage=` the board was opened on, or null.
  final int? requestedStageId;

  bool _visible = true;
  int? _seenStageId;

  bool get visible => _visible;

  /// Whether a stage report counts: only while the board is on screen.
  bool accept(int stageId) {
    if (!_visible) return false;
    _seenStageId = stageId;
    return true;
  }

  /// The board's visibility changed. Returns the stage page to re-show when
  /// this is a reveal, else null.
  int? setVisible(bool visible) {
    final revealed = visible && !_visible;
    _visible = visible;
    return revealed ? _seenStageId ?? requestedStageId : null;
  }
}

class BoardScreenState extends ConsumerState<BoardScreen> {
  late final BoardStageGate _gate = BoardStageGate(
    requestedStageId: widget.stageId,
  );
  GoRouter? _router;
  InAppWebViewController? _controller;

  /// The stage pages re-shown on reveal, in order — the test seam for the
  /// stubbed body, which has no webview to script.
  @visibleForTesting
  final List<int> shownStages = [];

  @visibleForTesting
  BoardStageGate get stageGate => _gate;

  // Subscribed here, not initState: GoRouter.of needs an inherited lookup.
  // maybeOf, because the bare-widget tests pump this screen with no router.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_router != null) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    _router = router;
    router.routerDelegate.addListener(_onRouteChanged);
    _gate.setVisible(
      BoardScreen.isOnTop(router.routerDelegate.currentConfiguration),
    );
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    super.dispose();
  }

  void _onRouteChanged() {
    final router = _router;
    if (router == null || !mounted) return;
    final stageId = _gate.setVisible(
      BoardScreen.isOnTop(router.routerDelegate.currentConfiguration),
    );
    if (stageId == null) return;
    shownStages.add(stageId);
    // After the frame that puts the board back on screen, so the page has its
    // real layout when it scrolls.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _controller;
      if (!mounted || controller == null) return;
      unawaited(
        controller.evaluateJavascript(
          source: BoardScreen.showStageScript(stageId),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final slug = ref.watch(currentBoardProvider.select((s) => s.slug));
    // `?stage=` belongs to the board it was opened on, and stage ids are
    // global: a switch from here drops it, so the new board opens on its first
    // page. This runs inside switchTo, before the remount builds its URL.
    ref.listen(currentBoardProvider.select((s) => s.slug), (prev, next) {
      if (widget.stageId != null &&
          prev != null &&
          prev != next &&
          context.mounted) {
        context.go(AppTab.board.path);
      }
    });
    final builder = widget.bodyBuilder;

    final Widget body;
    if (builder != null) {
      // Keyed by board so a switch remounts the body, as it does the webview.
      body = KeyedSubtree(
        key: ValueKey('board_body_${slug ?? ''}'),
        child: builder(context),
      );
    } else if (slug == null) {
      // No board: the router is already on its way to Choose a board.
      body = const SizedBox.shrink();
    } else {
      body = InAppWebView(
        // One key per board: initialUrlRequest only applies on mount, so a
        // switch has to remount to load the new board.
        key: ValueKey('board_webview_$slug'),
        initialSettings: embeddedWebViewSettings(),
        initialUrlRequest: URLRequest(
          url: WebUri(
            BoardScreen.boardUrl(slug: slug, stageId: widget.stageId),
          ),
        ),
        onWebViewCreated: (controller) {
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: 'relayCardTap',
            callback: (args) {
              final payload = args.isNotEmpty && args.first is Map
                  ? args.first as Map
                  : const <dynamic, dynamic>{};
              final path = BoardScreen.cardPathForTap(payload);
              if (path != null && context.mounted) {
                context.push(
                  path,
                  extra: BoardScreen.navContextForTap(payload),
                );
              }
            },
          );
          // RLY-126 · BOARD-04 — the board header "+" bubbles out of the
          // webview; the shell opens the native New-card sheet over the tab.
          controller.addJavaScriptHandler(
            handlerName: 'relayCreateCard',
            callback: (args) {
              final payload = args.isNotEmpty && args.first is Map
                  ? args.first as Map
                  : const <dynamic, dynamic>{};
              final request = CreateCardRequest.fromPayload(payload);
              if (request != null && context.mounted) {
                showNewCardSheet(context, request);
              }
            },
          );
          // RE376 · BOARD-01 — the embedded header's "<board> ▾" bubbles out;
          // the shell opens the same native Switch-board sheet as every tab.
          controller.addJavaScriptHandler(
            handlerName: BoardScreen.openSwitcherHandler,
            callback: (_) {
              if (context.mounted) showBoardSwitcherSheet(context);
            },
          );
          // RE452 — the pager reports the showing stage page; remember it so a
          // cold launch reopens the Board tab there. Not while a card covers
          // the board: that page is not what the user is looking at.
          controller.addJavaScriptHandler(
            handlerName: BoardScreen.stageChangedHandler,
            callback: (args) {
              if (args.isNotEmpty && args.first is Map) {
                final payload = args.first as Map;
                final stageId = BoardScreen._stageIdOf(payload);
                if (stageId == null || !_gate.accept(stageId)) return;
                BoardScreen.onStageChanged(ref, payload);
              }
            },
          );
          // RE452 — `?stage=` named a stage the board no longer has; the
          // pager fell back to the first page. Say why, if this was a restore.
          controller.addJavaScriptHandler(
            handlerName: BoardScreen.stageMissingHandler,
            callback: (args) {
              if (args.isNotEmpty && args.first is Map) {
                BoardScreen.onStageMissing(ref, args.first as Map);
              }
            },
          );
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          final status = errorResponse.statusCode ?? 0;
          final deadBoard =
              request.isForMainFrame == true &&
              status >= 400 &&
              BoardScreen.slugFromPath(request.url.path) != null;
          if (!deadBoard) return;
          // The current board is gone (deleted / membership revoked): forget it
          // app-wide and choose another, or every launch re-fails.
          ref.read(currentBoardProvider.notifier).clear();
          if (context.mounted) context.go('/choose-board');
        },
      );
    }

    return Scaffold(body: body);
  }
}
