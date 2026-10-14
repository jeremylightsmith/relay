/// The tab-shell roots, in tab-bar order (Needs you · Board · Settings) — the
/// only copy (AGENTS.md "a magic value is defined exactly once"). The router's
/// redirect, the bottom bar and the last-place tracker (RE452) all read it.
enum AppTab {
  needsYou('/needs-you'),
  board('/board'),
  settings('/settings');

  const AppTab(this.path);

  /// The tab's route.
  final String path;

  /// The tab whose root is exactly [path]; null for anything else (a card, a
  /// sub-route, scaffolding).
  static AppTab? fromPath(String path) {
    for (final tab in values) {
      if (tab.path == path) return tab;
    }
    return null;
  }
}
