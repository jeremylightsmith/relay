/// What iOS currently thinks about this app's microphone permission.
enum MicPermission { notDetermined, denied, granted }

enum VoiceErrorKind {
  /// The recorder never produced a usable file.
  recordingFailed,

  /// The bundled WhisperKit model failed to load — "Voice isn't available
  /// right now." Never a raw Swift error (spec error table).
  modelUnavailable,

  /// Transcription itself failed — "Didn't catch that."
  transcriptionFailed,
}

class VoiceError implements Exception {
  const VoiceError(this.kind);

  final VoiceErrorKind kind;

  @override
  String toString() => 'VoiceError(${kind.name})';
}

/// The engine seam (spec U1). An interface rather than a bare MethodChannel —
/// this is what makes VoiceController testable without the OS, and what makes
/// the eventual Android/whisper.cpp swap (D1/RLY-103) a new implementation
/// rather than a rewrite. Mirrors PushPlatform.
///
/// Two members beyond the spec's six, each forced by a row of its error table:
/// [onInterrupted] (a phone call stops recording and the partial clip is
/// transcribed, not thrown away) and [openSettings] (the previously-denied
/// row's "Open Settings" button).
abstract class VoiceTranscriber {
  Future<MicPermission> permissionStatus();

  /// Spends the one-shot OS prompt.
  Future<MicPermission> requestPermission();

  Future<void> startRecording();

  /// Stops and discards the in-progress recording.
  Future<void> cancelRecording();

  /// Stops recording and transcribes the captured clip. Throws [VoiceError].
  Future<String> stopAndTranscribe();

  /// Flags an in-flight [stopAndTranscribe] to end early; its result is
  /// discarded by the caller.
  Future<void> cancelTranscription();

  /// [handler] fires when the OS interrupts an active recording (phone call,
  /// route change). The controller treats it exactly like a Stop tap.
  void onInterrupted(void Function() handler);

  /// Opens the app's page in the iOS Settings app (previously-denied path).
  Future<void> openSettings();
}
