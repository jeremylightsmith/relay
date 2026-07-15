import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../config.dart';
import 'widgets/card_review_bar.dart';

/// The card-detail host: the native back bar, the **embedded chromeless LiveView card
/// body**, and a persistent native action bar beneath it (RLY-87 · CORE-03).
///
/// Per ADR 0001 this is a **thin wrapper over the existing LiveView**, not a parallel
/// native card UI: the body is `/cards/:ref`, the standalone chromeless route, which
/// renders the card drawer alone with no board and no web chrome. F2 already injected
/// the session cookie into the webview store, so it renders signed-in.
///
/// The bar swaps by [kind] and lives in `bottomNavigationBar` — outside the webview's
/// scroll, so no amount of body scrolling can lose it (brief §04).
class CardScreen extends StatelessWidget {
  const CardScreen({
    super.key,
    required this.cardRef,
    required this.boardSlug,
    this.kind,
    this.bodyBuilder,
  });

  final String cardRef;
  final String boardSlug;

  /// `in_review` | `needs_input`, from the inbox row or the push payload. Null/unknown
  /// renders no bar: the wrong bar on a card is worse than no bar.
  final String? kind;

  /// Overrides the webview body. `flutter test` runs on the host, where
  /// flutter_inappwebview has no platform implementation and throws on build —
  /// so tests inject a stub here. Same structural-seam idea as buildRouter's
  /// named params (see app/router.dart); null means the real webview.
  final WidgetBuilder? bodyBuilder;

  /// The embedded LiveView URL for a card. `/cards/:ref` is chromeless by construction,
  /// so `embed=1` is redundant — it is passed anyway to keep the Phoenix session flag
  /// set (via RelayWeb.Plugs.Embed) if the body ever navigates.
  static String cardUrl({
    required String cardRef,
    required String boardSlug,
    String? baseUrl,
  }) {
    final base = baseUrl ?? AppConfig.baseUrl;
    return '$base/cards/$cardRef?board=$boardSlug&embed=1';
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
      bottomNavigationBar: _actionBar(context),
    );
  }

  /// The action-bar slot. RLY-89 adds the `needs_input` answer bar here; until then the
  /// web stepper inside the body is still how V1-7 answers, so rendering nothing is
  /// correct.
  Widget? _actionBar(BuildContext context) {
    return switch (kind) {
      'in_review' => CardReviewBar(
        onApprove: () => _stub(context, 'Approve'),
        onReject: () => _stub(context, 'Reject'),
      ),
      _ => null,
    };
  }

  /// RLY-87 is the surface; RLY-88 replaces these bodies with the real API calls,
  /// the reject-note sheet and the result states. Say so out loud rather than
  /// failing silently.
  void _stub(BuildContext context, String action) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$action lands in RLY-88')));
  }
}
