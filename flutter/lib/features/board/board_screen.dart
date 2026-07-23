import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../card/card_nav_context.dart';
import 'board_prefs.dart';
import 'new_card_sheet.dart';

/// The Board tab: the **embedded chromeless LiveView board** (RLY-94 · BOARD-01),
/// opening on the remembered board (RLY-95 · BOARDS-00).
///
/// Cold start: the last-viewed slug is read from [BoardPrefs] — stored →
/// `/board/<slug>?embed=1`, nothing stored → the boards list `/boards?embed=1`
/// (never a server-picked default). The webview observes URL changes
/// (onUpdateVisitedHistory): landing on exactly `/board/<slug>` persists the slug;
/// visiting `/boards` does not clear it. If the remembered board fails to load
/// (main-frame HTTP ≥ 400 — deleted board or revoked membership), the slug is
/// cleared and the tab falls back to the boards list. No JS bridge for any of
/// this — the LiveView owns the list and the switch (ADR 0001).
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key, this.bodyBuilder});

  /// Overrides the webview body — same test seam as CardScreen.bodyBuilder:
  /// flutter_inappwebview has no host-platform implementation (RLY-81), so
  /// `flutter test` injects a stub. Null means the real webview.
  final WidgetBuilder? bodyBuilder;

  /// The embedded boards list (BOARDS-00) — the no-slug cold start and the
  /// dead-board fallback target.
  static String boardsListUrl({String? baseUrl}) {
    final base = baseUrl ?? AppConfig.baseUrl;
    return '$base/boards?embed=1';
  }

  /// The Board tab's initial URL: the remembered board when [slug] is stored,
  /// else the boards list (RLY-95 decision 4 — no server-picked default).
  static String boardUrl({String? baseUrl, String? slug}) {
    if (slug == null || slug.isEmpty) return boardsListUrl(baseUrl: baseUrl);
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
    final base = '/cards/$ref?board=$board';
    return kind == null ? base : '$base&kind=$kind';
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
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  late final Future<String> _initialUrl;

  @override
  void initState() {
    super.initState();
    _initialUrl = ref
        .read(boardPrefsProvider)
        .readLastBoardSlug()
        .then((slug) => BoardScreen.boardUrl(slug: slug));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body:
          widget.bodyBuilder?.call(context) ??
          FutureBuilder<String>(
            future: _initialUrl,
            builder: (context, snapshot) {
              final url = snapshot.data;
              // One or two frames while the Keychain read lands — blank beats
              // loading /boards and immediately swapping to the remembered board.
              if (url == null) return const SizedBox.shrink();
              return InAppWebView(
                key: const Key('board_webview'),
                initialUrlRequest: URLRequest(url: WebUri(url)),
                onWebViewCreated: (controller) {
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
                },
                onUpdateVisitedHistory: (controller, url, isReload) {
                  final slug = BoardScreen.slugFromPath(url?.path ?? '');
                  if (slug != null) {
                    ref.read(boardPrefsProvider).writeLastBoardSlug(slug);
                  }
                },
                onReceivedHttpError: (controller, request, errorResponse) {
                  final status = errorResponse.statusCode ?? 0;
                  final deadBoard =
                      request.isForMainFrame == true &&
                      status >= 400 &&
                      BoardScreen.slugFromPath(request.url.path) != null;
                  if (!deadBoard) return;
                  // The remembered board is gone (deleted / membership revoked):
                  // forget it and fall back to the list, or every launch re-fails.
                  ref.read(boardPrefsProvider).clear();
                  controller.loadUrl(
                    urlRequest: URLRequest(
                      url: WebUri(BoardScreen.boardsListUrl()),
                    ),
                  );
                },
              );
            },
          ),
    );
  }
}
