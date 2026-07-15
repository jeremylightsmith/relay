import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../config.dart';

/// A single card, opened by tapping a push notification (RLY-81).
///
/// Per ADR 0001 this is a **thin wrapper over the existing LiveView**, not a
/// parallel native card UI: it loads /board/:slug?card=:ref&embed=1, which is
/// how the web opens a card (BoardLive.handle_params/3) with F3's chromeless
/// embed mode on. F2 already injected the session cookie into the webview store,
/// so it renders signed-in.
class CardScreen extends StatelessWidget {
  const CardScreen({
    super.key,
    required this.cardRef,
    required this.boardSlug,
    this.bodyBuilder,
  });

  final String cardRef;
  final String boardSlug;

  /// Overrides the webview body. `flutter test` runs on the host, where
  /// flutter_inappwebview has no platform implementation and throws on build —
  /// so tests inject a stub here. Same structural-seam idea as buildRouter's
  /// named params (see app/router.dart); null means the real webview.
  final WidgetBuilder? bodyBuilder;

  /// The embedded LiveView URL for a card. `embed=1` is promoted into the Phoenix
  /// session by RelayWeb.Plugs.Embed, so it survives subsequent in-app nav.
  static String cardUrl({
    required String cardRef,
    required String boardSlug,
    String? baseUrl,
  }) {
    final base = baseUrl ?? AppConfig.baseUrl;
    return '$base/board/$boardSlug?card=$cardRef&embed=1';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(cardRef)),
      body:
          bodyBuilder?.call(context) ??
          InAppWebView(
            key: const Key('card_webview'),
            initialUrlRequest: URLRequest(
              url: WebUri(cardUrl(cardRef: cardRef, boardSlug: boardSlug)),
            ),
          ),
    );
  }
}
