import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'feed_controller.dart';
import 'models/feed_row.dart';
import 'widgets/caught_up.dart';
import 'widgets/inbox_row.dart';
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
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// D2: returning to the app never shows a stale queue.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(feedControllerProvider.notifier).refresh();
    }
  }

  /// D4: rows push /card/:ref, carrying `kind` so the host picks its bottom bar
  /// (RLY-87's review bar vs RLY-89's answer field). D2: acting on a card refetches.
  Future<void> _openCard(FeedRow row) async {
    await context.push('/card/${row.ref}?kind=${row.kind}');
    if (!mounted) return;
    await ref.read(feedControllerProvider.notifier).refresh();
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
              message: e is Exception ? _messageOf(e) : 'Something went wrong.',
              onRetry: () =>
                  ref.read(feedControllerProvider.notifier).refresh(),
            ),
            data: (s) => _Loaded(state: s, onOpen: _openCard),
          ),
        ),
      ],
    );
  }

  String _messageOf(Object e) {
    final raw = e.toString();
    // ApiException.toString is prefixed for logs; the UI wants the message alone.
    final marker = RegExp(r'^ApiException\([^)]*\): ');
    return raw.replaceFirst(marker, '');
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
            // Server order is authoritative (most-recently-blocked first) — no re-sort.
            ...state.rows.map(
              (row) => Padding(
                padding: const EdgeInsets.only(bottom: 14), // artboard 9
                child: InboxRow(
                  row: row,
                  showBoardChip: state.multiBoard,
                  onTap: () => onOpen(row),
                ),
              ),
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
