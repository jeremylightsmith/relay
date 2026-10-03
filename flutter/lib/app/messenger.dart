import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's one ScaffoldMessenger (RE376). It lets code with no BuildContext,
/// such as the push-tap handler, show a toast over whatever screen is up. A
/// SnackBar shown before any Scaffold exists (a cold launch) waits for the first one.
final scaffoldMessengerKeyProvider =
    Provider<GlobalKey<ScaffoldMessengerState>>(
      (ref) => GlobalKey<ScaffoldMessengerState>(),
    );
