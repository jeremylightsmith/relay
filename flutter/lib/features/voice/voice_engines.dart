import 'apple_speech_transcriber.dart';
import 'voice_engine_settings.dart';
import 'voice_transcriber.dart';
import 'whisper_kit_transcriber.dart';

/// The single voice test seam: both engines and the engine settings, taken
/// together by every voice consumer. Tests pass a fake's `engines`.
class VoiceEngines {
  const VoiceEngines({
    required this.whisper,
    required this.apple,
    required this.settings,
  });

  /// The real engines over `relay/voice` + `relay/voice/events`.
  factory VoiceEngines.platform() => VoiceEngines(
    whisper: WhisperKitTranscriber(),
    apple: AppleSpeechTranscriber(),
    settings: IosVoiceEngineSettings(),
  );

  /// Batch: words land after stop. The fallback engine.
  final VoiceTranscriber whisper;

  /// Live: words stream in while dictating (iOS 26). The default engine.
  final LiveVoiceTranscriber apple;

  final VoiceEngineSettings settings;
}
