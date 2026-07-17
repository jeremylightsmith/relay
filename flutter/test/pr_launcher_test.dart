import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/card/pr_launcher.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

/// Replays canned outcomes (bool or Exception) and records the modes asked for.
class RecordingLaunch {
  RecordingLaunch(this.results);

  final List<Object> results;
  final modes = <LaunchMode>[];

  Future<bool> call(Uri uri, LaunchMode mode) async {
    modes.add(mode);
    final next = results.removeAt(0);
    if (next is bool) return next;
    throw next as Exception;
  }
}

final _pr = Uri.parse('https://github.com/acme/relay/pull/42');

void main() {
  test(
    'a successful non-browser launch opens the GitHub app and stops',
    () async {
      final launch = RecordingLaunch([true]);

      expect(await PrLauncher(launch: launch.call).open(_pr), isTrue);
      expect(launch.modes, [LaunchMode.externalNonBrowserApplication]);
    },
  );

  test(
    'a refused non-browser launch retries with the in-app browser',
    () async {
      final launch = RecordingLaunch([false, true]);

      expect(await PrLauncher(launch: launch.call).open(_pr), isTrue);
      expect(launch.modes, [
        LaunchMode.externalNonBrowserApplication,
        LaunchMode.inAppBrowserView,
      ]);
    },
  );

  test('a throwing non-browser launch also falls back', () async {
    final launch = RecordingLaunch([
      PlatformException(code: 'ACTIVITY_NOT_FOUND'),
      true,
    ]);

    expect(await PrLauncher(launch: launch.call).open(_pr), isTrue);
    expect(launch.modes, [
      LaunchMode.externalNonBrowserApplication,
      LaunchMode.inAppBrowserView,
    ]);
  });

  test('both modes failing reports false for the caller snackbar', () async {
    final launch = RecordingLaunch([false, PlatformException(code: 'nope')]);

    expect(await PrLauncher(launch: launch.call).open(_pr), isFalse);
  });
}
