import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'board_summary.dart';

/// The app-icon badge (RE496): Σ [BoardSummary.needsYouCount] over the boards
/// the user has **not** muted — the sum of the switcher's amber pills, and the
/// same number the server's `Hamaca.Cards.needs_you_badge_count/1` sends in a
/// push. 0 for an empty list.
int iconBadgeCount(Iterable<BoardSummary> boards) =>
    boards.where((b) => !b.muted).fold(0, (sum, b) => sum + b.needsYouCount);

/// The OS app-icon badge seam. An interface so `BoardsController` is testable
/// without the OS (see test/support/fake_icon_badge.dart).
abstract class IconBadge {
  /// Sets the app-icon badge to [count]; 0 clears it. Never throws.
  Future<void> set(int count);
}

/// The real implementation, over the `setBadgeCount` method of the `relay/push`
/// channel in ios/Runner/AppDelegate.swift. iOS-only; a no-op elsewhere
/// (Android launcher badges are out of scope, and the test host has no OS).
///
/// Unlike `IosPushPlatform` it installs **no** method-call handler — a channel
/// has exactly one, and a second would steal push taps — so it is safe to build
/// any number of times.
class ChannelIconBadge implements IconBadge {
  static const MethodChannel _channel = MethodChannel('relay/push');

  @override
  Future<void> set(int count) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod<void>('setBadgeCount', {'count': count});
    } on PlatformException catch (_) {
      // A badge that could not be set is not worth surfacing; the next load or
      // a server badge push corrects it.
    } on MissingPluginException catch (_) {
      // Same: no native side (e.g. an older build), nothing to do.
    }
  }
}

final iconBadgeProvider = Provider<IconBadge>((ref) => ChannelIconBadge());
