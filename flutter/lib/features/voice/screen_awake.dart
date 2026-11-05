import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_transcriber.dart';

/// Toggles iOS `UIApplication.isIdleTimerDisabled` over the `relay/voice`
/// channel we already own — the IosVoiceEngineSettings pattern.
class IosScreenAwake implements ScreenAwake {
  /// The same channel WhisperKitTranscriber uses — **invoke-only**. Never call
  /// setMethodCallHandler here: a channel has exactly one handler, and
  /// WhisperKitTranscriber's owns `onInterrupted`. A second one would silently
  /// steal Whisper's interruptions.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('relay/voice');

  // The wire contract — mirrored once in VoicePlugin.swift.
  static const _setKeepAwake = 'setKeepAwake';
  static const _onArg = 'on';

  /// Never blocks dictation: a failure to toggle auto-lock is swallowed.
  @override
  Future<void> setKeepAwake(bool on) async {
    try {
      await channel.invokeMethod<void>(_setKeepAwake, {_onArg: on});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }
}
