import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_transcriber.dart';

/// Backed by iOS `UserDefaults` (key `relay.voice.engine`), over the
/// `relay/voice` channel we already own — the IosPushPrefs pattern, and for the
/// same reason: no `shared_preferences` dependency for a single scalar.
class IosVoiceEngineSettings implements VoiceEngineSettings {
  /// The same channel WhisperKitTranscriber uses — **invoke-only**. Never call
  /// setMethodCallHandler here: a channel has exactly one handler, and
  /// WhisperKitTranscriber's owns `onInterrupted`. A second one would silently
  /// steal Whisper's interruptions.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('relay/voice');

  // The wire contract — mirrored once in VoicePlugin.swift.
  static const _enginePreference = 'enginePreference';
  static const _setEnginePreference = 'setEnginePreference';
  static const _isTestFlight = 'isTestFlight';
  static const _engineArg = 'engine';

  @override
  Future<VoiceEngine> enginePreference() async {
    final name = await channel.invokeMethod<String>(_enginePreference);
    return VoiceEngine.values.firstWhere(
      (engine) => engine.name == name,
      orElse: () => VoiceEngine.apple,
    );
  }

  @override
  Future<void> setEnginePreference(VoiceEngine engine) => channel
      .invokeMethod<void>(_setEnginePreference, {_engineArg: engine.name});

  /// Never blocks dictation: any failure to ask reads as "not TestFlight".
  @override
  Future<bool> isTestFlight() async {
    try {
      return await channel.invokeMethod<bool>(_isTestFlight) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
