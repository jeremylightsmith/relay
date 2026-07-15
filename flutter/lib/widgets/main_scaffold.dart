import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app/theme.dart';
import '../features/needs_you/feed_controller.dart';

/// Bottom-nav shell: Needs you · Board · Settings. The current tab is derived from
/// the router location, so navigation state lives in the URL.
///
/// The Needs-you badge follows the live feed count (D6) — it must hit zero when you're
/// caught up (ADR 0005 §6), otherwise EMPTY-01's "You're all caught up" would sit next
/// to a permanently-lit "you have work" dot. This is the **in-app dot only**; the OS /
/// app-icon badge and push stay with RLY-81/F5.
class MainScaffold extends ConsumerWidget {
  const MainScaffold({super.key, required this.child});

  final Widget child;

  static const _tabPaths = ['/needs-you', '/board', '/settings'];

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    if (location.startsWith('/board')) return 1;
    if (location.startsWith('/settings')) return 2;
    return 0; // default: Needs you
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final count = ref.watch(needsYouCountProvider);

    return Scaffold(
      // Only the top inset: the NavigationBar below already reserves its own
      // bottom safe area, and doubling it here would add dead space above it.
      // (Carried forward from a RLY-85 follow-up fix — without this the
      // Needs-you header draws under the status bar / notch on device. Keep
      // this wrap when touching this file; don't paste-replace it away.)
      body: SafeArea(bottom: false, child: child),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex(context),
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        onDestinationSelected: (index) => context.go(_tabPaths[index]),
        destinations: [
          NavigationDestination(
            key: const Key('nav_needs_you'),
            icon: _needsYouIcon(
              const Icon(Icons.check_box_outline_blank),
              count: count,
            ),
            selectedIcon: _needsYouIcon(
              Icon(Icons.crop_square, color: scheme.primary),
              count: count,
            ),
            label: 'Needs you',
          ),
          NavigationDestination(
            key: const Key('nav_board'),
            icon: const Icon(Icons.grid_view_outlined),
            selectedIcon: Icon(Icons.grid_view, color: scheme.primary),
            label: 'Board',
          ),
          NavigationDestination(
            key: const Key('nav_settings'),
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: scheme.primary),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  /// The amber dot, only when something is actually waiting. `count == 0` → the bare
  /// icon, no Badge in the tree at all.
  Widget _needsYouIcon(Widget icon, {required int count}) {
    if (count == 0) return icon;
    return Badge(
      // amber dot · mockup oklch(0.70 0.13 65)
      backgroundColor: RelayTheme.relayBlocked,
      smallSize: 7,
      child: icon,
    );
  }
}
