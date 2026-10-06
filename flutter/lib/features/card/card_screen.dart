import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config.dart';
import '../decisions/review_queue.dart';
import 'card_nav_context.dart';
import 'card_summary.dart';
import 'pr_launcher.dart';
import 'widgets/card_context_chips.dart';
import 'widgets/card_review_bar.dart';

/// The card-detail host: the **embedded chromeless LiveView card
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
    this.navContext,
    this.backLabel,
    this.bodyBuilder,
  });

  final String cardRef;
  final String boardSlug;

  /// `in_review` | `needs_input`, from the inbox row or the push payload. Null/unknown
  /// renders no bar: the wrong bar on a card is worse than no bar.
  final String? kind;

  /// The ordered cards surrounding this one (RLY-234), for horizontal swipe nav. Null
  /// on a cold deep link / push (go_router `extra` is in-memory) → swipe is inert.
  final CardNavContext? navContext;

  /// The label of the screen this card was pushed from ([backFromBoard] or
  /// [backFromNeedsYou]), from the route's `back` query param (RE393). The web nav
  /// bar shows it after "‹"; null (an orphan push deep link) shows plain "Back".
  final String? backLabel;

  /// The JS handler the web nav bar's back control calls (RE393) — the only Dart
  /// copy of the name; the web side lives in the `.NativeBack` hook.
  static const navBackHandler = 'relayNavBack';

  /// The `back` labels for each entry path — the only Dart copies.
  static const backFromBoard = 'Board';
  static const backFromNeedsYou = 'Needs you';

  /// What the web nav bar's back control does: pop to wherever the card was pushed
  /// from, or — for a card opened by a push (RE376 · PUSH-01: a root route with
  /// nothing to pop) — land on the now-current board's Needs you, never a dead end.
  static void navBack(GoRouter router) {
    if (router.canPop()) {
      router.pop();
    } else {
      router.go('/needs-you');
    }
  }

  /// The JS handler the embedded mockup viewer calls (RE393) with `true` when it
  /// opens and `false` when it closes — the only Dart copy of the name; the web
  /// side lives in the `.NativeMockupViewer` hook.
  static const mockupViewerHandler = 'relayMockupViewer';

  /// Decodes the [mockupViewerHandler] args: open only for a leading literal
  /// `true`, so a malformed call can never strand the card with its swipe off.
  static bool mockupViewerOpenFromArgs(List<dynamic> args) =>
      args.isNotEmpty && args.first == true;

  /// Records whether the embedded mockup viewer is open on the enclosing card
  /// screen. The [mockupViewerHandler] callback lands here — a static, testable
  /// entry point (the real webview can't build under `flutter test`). A no-op
  /// outside a [CardScreen]. The callback's context is the screen's own (an
  /// ancestor lookup starts *above* it), so that element is checked first.
  static void setMockupViewerOpen(BuildContext context, bool open) {
    final own = context is StatefulElement ? context.state : null;
    final state = own is _CardScreenState
        ? own
        : context.findAncestorStateOfType<_CardScreenState>();
    state?._setMockupViewerOpen(open);
  }

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
    String? backLabel,
    String? baseUrl,
  }) {
    final base = baseUrl ?? AppConfig.baseUrl;
    return '$base/cards/$cardRef?board=$boardSlug&embed=1${_backParam(backLabel)}';
  }

  /// `&back=<encoded label>`, or nothing for a null/empty label — shared by the
  /// webview URL and the swipe's replacement route so both encode it once.
  static String _backParam(String? backLabel) =>
      backLabel == null || backLabel.isEmpty
      ? ''
      : '&back=${Uri.encodeQueryComponent(backLabel)}';

  /// The webview's bid in Flutter's gesture arena. A platform view only receives a
  /// touch once one of these wins, so without a vertical recognizer the swipe
  /// GestureDetector's horizontal recognizer was the sole contender: a vertical drag
  /// stayed unresolved until pointer-up and the card body would (mostly) not scroll.
  ///
  /// - Viewer closed: Vertical claims vertical drags; horizontal ones still reach
  ///   the swipe handler.
  /// - Viewer open (RE393): Eager hands the WKWebView every touch, so a mockup can
  ///   pan sideways and pinch-zoom natively; the card swipe stands down meanwhile.
  static Set<Factory<OneSequenceGestureRecognizer>>
  webviewGestureRecognizersFor({required bool mockupViewerOpen}) =>
      mockupViewerOpen
      ? {Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new)}
      : {
          Factory<VerticalDragGestureRecognizer>(
            VerticalDragGestureRecognizer.new,
          ),
        };

  @override
  ConsumerState<CardScreen> createState() => _CardScreenState();
}

class _CardScreenState extends ConsumerState<CardScreen> {
  /// Accumulated horizontal drag distance for the in-progress swipe. Positive =
  /// rightward (→ previous card), negative = leftward (→ next) — mirrors the web hook.
  double _dragDx = 0;

  /// Logical pixels a horizontal drag must pass to commit to a neighbor; below it the
  /// drag is ignored, so an incidental sideways nudge never navigates.
  static const double _swipeCommitThreshold = 60;

  /// Whether the embedded mockup viewer is open (RE393), set through
  /// [CardScreen.setMockupViewerOpen]. While true the webview takes every gesture
  /// and the card swipe is off.
  bool _mockupViewerOpen = false;

  void _setMockupViewerOpen(bool open) {
    if (open == _mockupViewerOpen) return;
    setState(() => _mockupViewerOpen = open);
  }

  @override
  void initState() {
    super.initState();
    _seedIfNeeded();
    _scheduleBanner();
  }

  /// Decide the just-finished horizontal drag. A committed rightward drag steps to the
  /// previous card, leftward to the next. At a list boundary (neighbor null) or with no
  /// nav context it is a no-op — no wrap, no crash. Commit *replaces* the route, carrying
  /// the context re-centered on the neighbor, so Back still returns to the originating
  /// list (Decision 3 — mirrors navigateQueue's pushReplacement).
  void _commitSwipe() {
    final dx = _dragDx;
    _dragDx = 0;
    if (dx.abs() < _swipeCommitThreshold) return;
    final target = dx > 0 ? widget.navContext?.prev : widget.navContext?.next;
    if (target == null) return;
    final kindParam = target.kind == null ? '' : '&kind=${target.kind}';
    // The swiped-to card keeps the label of the list it was opened from.
    final backParam = CardScreen._backParam(widget.backLabel);
    GoRouter.of(context).pushReplacement(
      '/cards/${target.ref}?board=${target.boardSlug}$kindParam$backParam',
      extra: widget.navContext?.at(target.ref),
    );
  }

  // go_router's default page key is derived from the route *pattern*
  // (`/cards/:ref`), not the resolved path — advancing from RLY-A's card to
  // RLY-B's via pushReplacement reuses this State rather than remounting it
  // (the same trap a per-card stateful body always has). didUpdateWidget is what notices the
  // ref changed.
  @override
  void didUpdateWidget(covariant CardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.cardRef != oldWidget.cardRef ||
        widget.boardSlug != oldWidget.boardSlug) {
      // The new card's page has no viewer open yet (RE393).
      _mockupViewerOpen = false;
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
  /// on (the post-frame banner pattern) — the D1 replacement
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

    // RE393: no AppBar — the embedded page's web nav bar owns the top bar and
    // pads itself by env(safe-area-inset-top), so the body must not add a top
    // inset too (it would double-pad). Its back control calls [navBackHandler].
    return Scaffold(
      // Advancing reuses this State (see didUpdateWidget) — and an *updated*
      // InAppWebView keeps the old card's page, since initialUrlRequest only
      // applies on mount. The per-card key remounts the body so the new card
      // actually loads.
      body: SafeArea(
        top: false,
        child: GestureDetector(
          key: const Key('card_swipe_area'),
          // Horizontal only: the webview owns vertical scroll via its
          // [CardScreen.webviewGestureRecognizersFor], so the arena gives vertical
          // drags to the page and only a horizontal drag reaches these callbacks
          // (RLY-234 — mirrors the web hook's |dx|>|dy| rule). While the mockup
          // viewer is open the callbacks are null, so no horizontal recognizer
          // enters the arena and the mockup gets the sideways pan (RE393).
          onHorizontalDragStart: _mockupViewerOpen ? null : (_) => _dragDx = 0,
          onHorizontalDragUpdate: _mockupViewerOpen
              ? null
              : (d) => _dragDx += d.delta.dx,
          onHorizontalDragEnd: _mockupViewerOpen ? null : (_) => _commitSwipe(),
          child: KeyedSubtree(
            key: ValueKey('card_body_${widget.cardRef}'),
            child:
                widget.bodyBuilder?.call(context) ??
                InAppWebView(
                  key: const Key('card_webview'),
                  // Never key the webview on the flag: a remount reloads the page
                  // and drops the viewer. The platform view picks up the new set
                  // on rebuild.
                  gestureRecognizers: CardScreen.webviewGestureRecognizersFor(
                    mockupViewerOpen: _mockupViewerOpen,
                  ),
                  initialUrlRequest: URLRequest(
                    url: WebUri(
                      CardScreen.cardUrl(
                        cardRef: widget.cardRef,
                        boardSlug: widget.boardSlug,
                        // Read from the widget, never cached: go_router reuses
                        // this State across pushReplacement.
                        backLabel: widget.backLabel,
                      ),
                    ),
                  ),
                  // A full page load means the viewer's destroyed() never ran.
                  onLoadStart: (_, _) => _setMockupViewerOpen(false),
                  onWebViewCreated: (controller) {
                    controller.addJavaScriptHandler(
                      handlerName: CardScreen.navBackHandler,
                      callback: (_) {
                        if (context.mounted) {
                          CardScreen.navBack(GoRouter.of(context));
                        }
                      },
                    );
                    controller.addJavaScriptHandler(
                      handlerName: CardScreen.mockupViewerHandler,
                      callback: (args) {
                        if (context.mounted) {
                          CardScreen.setMockupViewerOpen(
                            context,
                            CardScreen.mockupViewerOpenFromArgs(args),
                          );
                        }
                      },
                    );
                  },
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
