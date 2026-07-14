import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../app/theme.dart';

/// Bottom-nav shell: Needs you · Board · Settings. Stateless — the current tab
/// is derived from the router location, so navigation state lives in the URL.
class MainScaffold extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex(context),
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        onDestinationSelected: (index) => context.go(_tabPaths[index]),
        destinations: [
          NavigationDestination(
            key: const Key('nav_needs_you'),
            icon: const Badge(
              backgroundColor: RelayTheme
                  .relayBlocked, // amber dot · mockup oklch(0.70 0.13 65)
              smallSize: 7,
              child: Icon(Icons.check_box_outline_blank),
            ),
            selectedIcon: Badge(
              backgroundColor: RelayTheme.relayBlocked,
              smallSize: 7,
              child: Icon(Icons.crop_square, color: scheme.primary),
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
}
