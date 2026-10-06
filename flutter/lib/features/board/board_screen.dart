import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../boards/board_switcher.dart';
import '../boards/current_board.dart';
import '../card/card_nav_context.dart';
import '../card/card_screen.dart';
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
class BoardScreen extends ConsumerWidget {
  const BoardScreen({super.key, this.bodyBuilder});

  /// Overrides the webview body — same test seam as CardScreen.bodyBuilder:
  /// flutter_inappwebview has no host-platform implementation (RLY-81), so
  /// `flutter test` injects a stub. Null means the real webview.
  final WidgetBuilder? bodyBuilder;

  /// The JS bridge the embedded header's board title calls (board_pager.js).
  static const openSwitcherHandler = 'relayOpenBoardSwitcher';

  /// The Board tab's URL: [slug], embedded.
  static String boardUrl({String? baseUrl, required String slug}) {
    final base = baseUrl ?? AppConfig.baseUrl;
    return '$base/board/$slug?embed=1';
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

  /// The swipe navigation context for a `relayCardTap` payload (RLY-234): the tapped
  /// column's ordered `cards: [{ref, kind}]` (emitted by board_live's card-tap bridge),
  /// as a [CardNavContext] seeked to the tapped ref. Null when the payload carries no
  /// column (a build/browser fallback with no `cards`) — swipe is then inert.
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
  Widget build(BuildContext context, WidgetRef ref) {
    final slug = ref.watch(currentBoardProvider.select((s) => s.slug));
    final builder = bodyBuilder;

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
        initialUrlRequest: URLRequest(url: WebUri(boardUrl(slug: slug))),
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(
            handlerName: 'relayCardTap',
            callback: (args) {
              final payload = args.isNotEmpty && args.first is Map
                  ? args.first as Map
                  : const <dynamic, dynamic>{};
              final path = cardPathForTap(payload);
              if (path != null && context.mounted) {
                context.push(path, extra: navContextForTap(payload));
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
            handlerName: openSwitcherHandler,
            callback: (_) {
              if (context.mounted) showBoardSwitcherSheet(context);
            },
          );
        },
        onReceivedHttpError: (controller, request, errorResponse) {
          final status = errorResponse.statusCode ?? 0;
          final deadBoard =
              request.isForMainFrame == true &&
              status >= 400 &&
              slugFromPath(request.url.path) != null;
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
