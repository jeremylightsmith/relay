import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';

/// The Board tab: the **embedded chromeless LiveView board** (RLY-94 · BOARD-01).
///
/// Per ADR 0001 this is a thin wrapper over the existing LiveView — the pager,
/// swipe, chips, compose, and moves are all owned by the web board. The shell only
/// hosts it and handles one escape hatch: a card tap bubbles out via the
/// `relayCardTap` JS handler and pushes the existing native CardScreen (BOARD-03).
///
/// `/board` is the slugless redirect: RelayWeb.Plugs.Embed promotes `?embed=1`
/// into the session before BoardRedirectController resolves the user's default
/// board, so the redirected `/board/<slug>` request stays chromeless. The session
/// cookie was injected at sign-in (F2), so the webview renders signed-in. No
/// native AppBar: the board's compact header + chip strip render inside the page.
class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key, this.bodyBuilder});

  /// Overrides the webview body — same test seam as CardScreen.bodyBuilder:
  /// flutter_inappwebview has no host-platform implementation (RLY-81), so
  /// `flutter test` injects a stub. Null means the real webview.
  final WidgetBuilder? bodyBuilder;

  /// The embedded LiveView URL for the Board tab.
  static String boardUrl({String? baseUrl}) {
    final base = baseUrl ?? AppConfig.baseUrl;
    return '$base/board?embed=1';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body:
          bodyBuilder?.call(context) ??
          InAppWebView(
            key: const Key('board_webview'),
            initialUrlRequest: URLRequest(url: WebUri(boardUrl())),
            onWebViewCreated: (controller) {
              controller.addJavaScriptHandler(
                handlerName: 'relayCardTap',
                callback: (args) {
                  final payload = args.isNotEmpty && args.first is Map
                      ? args.first as Map
                      : const <dynamic, dynamic>{};
                  final path = cardPathForTap(payload);
                  if (path != null && context.mounted) context.push(path);
                },
              );
            },
          ),
    );
  }
}
