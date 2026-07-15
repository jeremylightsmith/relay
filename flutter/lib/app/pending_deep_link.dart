import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The route a launch was *for*, held while auth resolves.
///
/// Last write wins: a cold start stashes the initial location first, and the push
/// tap's navigation arrives moments later while auth is still restoring —
/// first-wins would silently drop the card, which is the whole point of RLY-86.
///
/// A plain class behind a [Provider], not a Notifier: nothing watches it (only the
/// router's redirect reads and writes it, and `refreshListenable` already re-runs
/// that on every status change), and writing to a notifier from inside a redirect
/// courts Riverpod's "modified a provider while the tree was building" guard.
class PendingDeepLink {
  String? _location;

  void set(String location) => _location = location;

  /// Read and clear — a resume must happen exactly once.
  String? take() {
    final location = _location;
    _location = null;
    return location;
  }
}

final pendingDeepLinkProvider = Provider<PendingDeepLink>(
  (ref) => PendingDeepLink(),
);
