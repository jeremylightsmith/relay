import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../decisions/review_queue.dart';
import 'card_summary.dart';
import 'pr_launcher.dart';
import 'widgets/card_context_chips.dart';
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
///
/// RLY-88 wires the bar: Approve posts through [ReviewQueue.approveCurrent] and
/// auto-advances (D1 — no confirmation screens); Reject opens the CORE-07 note
/// screen. Arrivals the inbox tap didn't snapshot (a push deep link) are seeded as a
/// one-item queue here, so the bar is never dead and never decides a different card
/// than the one on screen.
class CardScreen extends ConsumerStatefulWidget {
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
  ConsumerState<CardScreen> createState() => _CardScreenState();
}

class _CardScreenState extends ConsumerState<CardScreen> {
  @override
  void initState() {
    super.initState();
    _seedIfNeeded();
    _scheduleBanner();
  }

  // go_router's default page key is derived from the route *pattern*
  // (`/cards/:ref`), not the resolved path — advancing from RLY-A's card to
  // RLY-B's via pushReplacement reuses this State rather than remounting it
  // (same trap AnswerScreen documents). didUpdateWidget is what notices the
  // ref changed.
  @override
  void didUpdateWidget(covariant CardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cardRef != oldWidget.cardRef ||
        widget.boardSlug != oldWidget.boardSlug) {
      _seedIfNeeded();
      _scheduleBanner();
    }
  }

  /// An inbox tap snapshots the queue before pushing here, and a queue advance
  /// lands with the cursor already on this card — both match and are left
  /// alone (the snapshot's order is the whole point, D3). A push deep link or
  /// a stale stack doesn't match: seed a one-item snapshot so Approve decides
  /// *this* card, and the end-of-snapshot refetch picks the walk up from the
  /// live feed. This closes pathForPayload's "RLY-88 must handle it" note —
  /// a stale push's wrong `kind` resolves as a 422 skip, not an error.
  ///
  /// The actual notifier write is deferred a frame (same reason as
  /// [_scheduleBanner]): Riverpod forbids modifying a provider synchronously
  /// from a widget lifecycle method (initState/didUpdateWidget/build), so
  /// seeding here — not from a button's onPressed — must happen post-frame.
  void _seedIfNeeded() {
    if (widget.kind != 'in_review') return;
    final current = ref.read(reviewQueueProvider).current;
    if (current != null &&
        current.ref == widget.cardRef &&
        current.boardSlug == widget.boardSlug) {
      return;
    }
    final item = QueueItem(
      ref: widget.cardRef,
      boardSlug: widget.boardSlug,
      boardName: '',
      title: '',
      kind: widget.kind!,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(reviewQueueProvider.notifier).enterSingle(item);
    });
  }

  /// The banner belongs to the card just decided, shown over the one we land
  /// on (same pattern as AnswerScreen._scheduleBanner) — the D1 replacement
  /// for the superseded CORE-06/CORE-08 confirmation screens.
  void _scheduleBanner() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final banner = ref.read(reviewQueueProvider.notifier).takeBanner();
      if (banner != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(banner)));
      }
    });
  }

  Future<void> _approve() async {
    final dest = await ref
        .read(reviewQueueProvider.notifier)
        .approveCurrent(cardRef: widget.cardRef, boardSlug: widget.boardSlug);
    if (!mounted || dest == null) return;
    navigateQueue(GoRouter.of(context), dest);
  }

  void _reject() {
    context.push('/card/${widget.cardRef}/reject?board=${widget.boardSlug}');
  }

  /// Decision 4's chain lives in PrLauncher; total failure is the only user-visible
  /// error this feature has (supplemental context never blocks the primary action).
  Future<void> _openPr(Uri uri) async {
    final opened = await ref.read(prLauncherProvider).open(uri);
    if (!mounted || opened) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Couldn't open the PR.")));
  }

  @override
  Widget build(BuildContext context) {
    // A failed decision surfaces here (spec: snackbar + Retry, stay put).
    // Only when this screen is current — the reject screen handles its own
    // failures with an inline strip, and must not get a second snackbar.
    ref.listen(reviewQueueProvider.select((s) => s.error), (previous, error) {
      if (error == null || !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error),
          action: SnackBarAction(label: 'Retry', onPressed: _approve),
        ),
      );
    });

    return Scaffold(
      appBar: AppBar(title: Text(widget.cardRef)),
      // Advancing reuses this State (see didUpdateWidget) — and an *updated*
      // InAppWebView keeps the old card's page, since initialUrlRequest only
      // applies on mount. The per-card key remounts the body so the new card
      // actually loads.
      body: KeyedSubtree(
        key: ValueKey('card_body_${widget.cardRef}'),
        child:
            widget.bodyBuilder?.call(context) ??
            InAppWebView(
              key: const Key('card_webview'),
              initialUrlRequest: URLRequest(
                url: WebUri(
                  CardScreen.cardUrl(
                    cardRef: widget.cardRef,
                    boardSlug: widget.boardSlug,
                  ),
                ),
              ),
            ),
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  /// The native bottom chrome: the context-chip strip (RLY-98) stacked over the review
  /// bar (RLY-87) in one min-size Column, so the chip survives every entry path —
  /// including needs_input cards, where no review bar renders. The ColoredBox + outer
  /// SafeArea keep the surface painted under the home indicator whichever children
  /// render (CardReviewBar's own SafeArea becomes a no-op inside this one). The chip
  /// hides until the summary fetch lands (value is null while loading and on
  /// every failure — the spec's failure posture).
  Widget? _bottomBar() {
    final prUrl = ref
        .watch(
          cardPrUrlProvider((
            cardRef: widget.cardRef,
            boardSlug: widget.boardSlug,
          )),
        )
        .value;
    final reviewBar = _actionBar();
    if (prUrl == null && reviewBar == null) return null;

    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (prUrl != null) CardContextChips(onOpenPr: () => _openPr(prUrl)),
            ?reviewBar,
          ],
        ),
      ),
    );
  }

  /// The action-bar slot. RLY-89's needs_input answering still happens through
  /// the web stepper inside the body, so rendering nothing there is correct.
  Widget? _actionBar() {
    final inFlight = ref.watch(reviewQueueProvider.select((s) => s.inFlight));
    return switch (widget.kind) {
      // Disabling while a POST is in flight is the visible half of the
      // double-tap guard (the queue's inFlight short-circuit is the
      // authoritative half). Approve/reject are irreversible — no domain
      // undo — so both go quiet together.
      'in_review' => CardReviewBar(
        onApprove: inFlight ? null : _approve,
        onReject: inFlight ? null : _reject,
      ),
      _ => null,
    };
  }
}
