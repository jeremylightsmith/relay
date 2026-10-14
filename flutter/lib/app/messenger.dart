import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's one ScaffoldMessenger (RE376). It lets code with no BuildContext,
/// such as the push-tap handler, show a toast over whatever screen is up. A
/// SnackBar shown before any Scaffold exists (a cold launch) waits for the first one.
final scaffoldMessengerKeyProvider =
    Provider<GlobalKey<ScaffoldMessengerState>>(
      (ref) => GlobalKey<ScaffoldMessengerState>(),
    );

/// How long a toast stays up — the push board-switch toast's 2 s (RE376), the
/// only copy.
const toastDuration = Duration(seconds: 2);

/// The app's one toast: a plain SnackBar over whatever screen is up, no action.
/// The push board switch (RE376) and the launch restore's fallbacks (RE452)
/// both show theirs through here, each with its own [key] for tests.
void showToast(
  GlobalKey<ScaffoldMessengerState> messenger,
  String text, {
  Key key = const Key('app_toast'),
}) {
  messenger.currentState?.showSnackBar(
    SnackBar(key: key, content: Text(text), duration: toastDuration),
  );
}
