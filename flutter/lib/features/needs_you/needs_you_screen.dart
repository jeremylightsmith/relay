import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../card/card_nav_context.dart';
import '../decisions/review_queue.dart';
import 'feed_controller.dart';
import 'models/feed_row.dart';
import 'widgets/caught_up.dart';
import 'widgets/inbox_row.dart';
import 'widgets/stage_group_header.dart';
import 'widgets/working_strip.dart';

/// The "Needs you" inbox — HOME-01 / EMPTY-01 (docs/designs/Relay Mobile.dc.html).
///
/// A Layer-1 *native* decision surface per ADR 0005 §5: the list is native; tapping
/// a row hands off to the card-detail host. Composition only — the states below are
/// assembled from pure widgets and the FeedController's AsyncValue.
class NeedsYouScreen extends ConsumerStatefulWidget {
  const NeedsYouScreen({super.key});

  @override
  ConsumerState<NeedsYouScreen> createState() => _NeedsYouScreenState();
}

class _NeedsYouScreenState extends ConsumerState<NeedsYouScreen>
    with WidgetsBindingObserver {
  GoRouter? _router;
  bool _atNeedsYou = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// RLY-128 D1: refresh when the inbox regains focus. One router listener
  /// covers both staleness gaps — tab switches AND pop-backs from any pushed
  /// screen (card host, reject, answer, including webview-driven card edits
  /// made on the card screen) — throttled by refreshIfStale's 15s guard.
  /// Subscribed here, not initState: GoRouter.of needs an inherited lookup.
  /// maybeOf, because the bare-widget tests pump this screen with no router.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_router != null) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    _router = router;
    router.routerDelegate.addListener(_onRouteChanged);
    _atNeedsYou = _location(router) == '/needs-you';
    // A fresh mount already sitting on /needs-you is itself a focus gain
    // (the shell rebuilds tab pages). On the very first mount the provider's
    // own build() is the in-flight fetch, so the guard makes this call free.
    if (_atNeedsYou) {
      unawaited(ref.read(feedControllerProvider.notifier).refreshIfStale());
    }
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_onRouteChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The topmost matched location. Deliberately reads `matches.last`, not
  /// `currentConfiguration.uri` — the latter only reflects *declarative*
  /// matches (`go`) and is frozen at the underlying tab's location for the
  /// whole time an *imperative* `push` (card host, reject, answer) sits on
  /// top of it, so it would never see a pop-back as a location change.
  String _location(GoRouter router) {
    final matches = router.routerDelegate.currentConfiguration.matches;
    return matches.isEmpty ? '' : matches.last.matchedLocation;
  }

  void _onRouteChanged() {
    final router = _router;
    if (router == null || !mounted) return;
    final here = _location(router) == '/needs-you';
    if (here && !_atNeedsYou) {
      unawaited(ref.read(feedControllerProvider.notifier).refreshIfStale());
    }
    _atNeedsYou = here;
  }

  /// D2: returning to the app never shows a stale queue. Deliberately the
  /// unconditional refresh (RLY-85) — the 15s guard applies only to
  /// focus-triggered refreshes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(feedControllerProvider.notifier).refresh();
    }
  }

  /// D4: rows push the card's screen — a needs_input row opens RLY-89's answer
  /// screen, an in_review row the card host (carrying `kind` so it picks its
  /// bottom bar).
  ///
  /// RLY-88: the tap is also where the review queue is snapshotted — the rows
  /// the human can see are exactly the queue they will clear, in that order.
  /// RLY-128: no post-pop refresh here — the focus listener covers the way
  /// back (and a queue-walk exit via `router.go` never completed this
  /// method's awaited push anyway), and D2's per-decision reconcile already
  /// updated the feed.
  void _openCard(FeedRow row) {
    final rows =
        ref.read(feedControllerProvider).value?.rows ?? const <FeedRow>[];
    ref.read(reviewQueueProvider.notifier).enter(rows: rows, atRef: row.ref);
    final navContext = CardNavContext.seed(
      items: rows
          .map(
            (r) =>
                CardNavItem(ref: r.ref, boardSlug: r.board.slug, kind: r.kind),
          )
          .toList(growable: false),
      currentRef: row.ref,
    );
    unawaited(
      context.push(routeFor(QueueItem.fromRow(row)), extra: navContext),
    );
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(feedControllerProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          subtitle: feed.when(
            data: (s) => s.caughtUp
                ? 'nothing waiting' // EMPTY-01, literal lowercase
                : '${s.count} ${s.count == 1 ? 'decision' : 'decisions'} waiting',
            loading: () => '',
            error: (_, _) => '',
          ),
        ),
        Expanded(
          child: feed.when(
            loading: () => const Center(
              key: Key('feed_loading'),
              child: CircularProgressIndicator(),
            ),
            error: (e, _) => _ErrorState(
              message: e is ApiException ? e.message : 'Something went wrong.',
              onRetry: () =>
                  ref.read(feedControllerProvider.notifier).refresh(),
            ),
            data: (s) => _Loaded(state: s, onOpen: _openCard),
          ),
        ),
      ],
    );
  }
}

/// HOME-01 / EMPTY-01's in-page header (not an AppBar): 22px title over a live subtitle.
class _Header extends StatelessWidget {
  const _Header({required this.subtitle});

  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      key: const Key('needs_you_header'),
      padding: const EdgeInsets.fromLTRB(
        28,
        10,
        28,
        19,
      ), // artboard 18 / 6 / 12
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Needs you',
            style: TextStyle(
              fontSize: 34, // artboard 22 × 1.585 ≈ the iOS large-title size
              fontWeight: FontWeight.w600,
              letterSpacing: -1.0, // artboard -0.03em
              color: scheme.onSurface,
            ),
          ),
          Text(
            subtitle,
            key: const Key('needs_you_subtitle'),
            style: TextStyle(
              fontSize: 18, // artboard 11.5
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The loaded queue: HOME-01's list, or EMPTY-01's caught-up body. Both scroll,
/// so pull-to-refresh works even when caught up.
class _Loaded extends ConsumerWidget {
  const _Loaded({required this.state, required this.onOpen});

  final FeedState state;
  final void Function(FeedRow row) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final working = state.meta.workingCount;
    // D1: absent or 0 → the strip is not rendered at all. No gap, no placeholder.
    final showWorking = working != null && working > 0;

    return RefreshIndicator(
      onRefresh: () => ref.read(feedControllerProvider.notifier).refresh(),
      child: ListView(
        key: const Key('inbox_list'),
        // AlwaysScrollable so a short/empty list can still be pulled.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20), // artboard 12
        children: [
          if (state.caughtUp)
            const CaughtUp()
          else
            // Server order is authoritative *inside* a group (most-recently-blocked first) —
            // rows are never re-sorted. groupRowsByStage only *regroups* and orders the groups
            // by board position (RLY-156 re-plan): an earlier stage's bar sits above a later
            // stage's even when the later stage holds the newest block.
            ...groupRowsByStage(state.rows).expand(
              (group) => [
                StageGroupHeader(
                  name: group.group?.name ?? '',
                  type: group.group?.type,
                  count: group.rows.length,
                ),
                ...group.rows.map(
                  (row) => Padding(
                    padding: const EdgeInsets.only(bottom: 14), // artboard 9
                    child: InboxRow(
                      row: row,
                      showBoardChip: state.multiBoard,
                      onTap: () => onOpen(row),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          if (showWorking) ...[
            const SizedBox(height: 24),
            WorkingStrip(count: working),
          ],
        ],
      ),
    );
  }
}

/// D5 / the error state: never the caught-up body. A signed-in user with no token,
/// or an offline device, must never look "caught up".
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              message,
              key: const Key('feed_error'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('feed_retry'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
