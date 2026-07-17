import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a PR URL per RLY-98's decision 4: try the GitHub app first — the plain https
/// URL in [LaunchMode.externalNonBrowserApplication], which iOS universal links route
/// into the app when installed — then fall back to the in-app browser
/// ([LaunchMode.inAppBrowserView] — SFSafariViewController, so dismissing lands back on
/// the card screen). Returns false only when both fail; the caller owns the snackbar.
///
/// `launch` is the test seam (same structural-seam idea as CardScreen.bodyBuilder):
/// url_launcher has no host platform implementation under `flutter test`.
class PrLauncher {
  PrLauncher({Future<bool> Function(Uri uri, LaunchMode mode)? launch})
    : _launch = launch ?? _launchUrl;

  static Future<bool> _launchUrl(Uri uri, LaunchMode mode) =>
      launchUrl(uri, mode: mode);

  final Future<bool> Function(Uri uri, LaunchMode mode) _launch;

  Future<bool> open(Uri uri) async {
    try {
      if (await _launch(uri, LaunchMode.externalNonBrowserApplication)) {
        return true;
      }
    } on Exception {
      // A refused or unsupported non-browser launch falls through to the browser.
    }
    try {
      return await _launch(uri, LaunchMode.inAppBrowserView);
    } on Exception {
      return false;
    }
  }
}

final prLauncherProvider = Provider<PrLauncher>((ref) => PrLauncher());
