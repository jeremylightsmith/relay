import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a URL in a given [LaunchMode] — the shape of `launchUrl` itself.
typedef UrlLaunch = Future<bool> Function(Uri uri, LaunchMode mode);

/// The launch seam for Settings' outbound links (RE397's "Suggest an idea" →
/// the system browser, [LaunchMode.externalApplication]; RE510's "Support &
/// safety" → the in-app browser, [LaunchMode.inAppBrowserView]). Same seam
/// shape as PrLauncher's `launch`, minus its GitHub-app → in-app-browser
/// chain: url_launcher has no host platform implementation under
/// `flutter test`, so tests override this provider with a recorder.
final externalUrlLauncherProvider = Provider<UrlLaunch>(
  (ref) =>
      (uri, mode) => launchUrl(uri, mode: mode),
);
