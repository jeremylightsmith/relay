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

  /// Apple's on-device SpeechTranscriber model could not be downloaded.
  assetDownloadFailed,
}

class VoiceError implements Exception {
  const VoiceError(this.kind);

  final VoiceErrorKind kind;

  @override
  String toString() => 'VoiceError(${kind.name})';
}

/// The engine seam (spec U1). An interface rather than a bare MethodChannel —
/// this is what makes DictationController testable without the OS, and what
/// makes the eventual Android/whisper.cpp swap (D1/RLY-103) a new implementation
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

/// The on-device engines a dictation can run on. The wire names (the
/// `relay/voice` channel, the stored preference) are the enum `.name`s.
enum VoiceEngine { apple, whisper }

/// Whether Apple's live engine can run on this phone right now.
enum LiveSupport {
  /// Below iOS 26, or the device locale has no SpeechTranscriber model.
  unsupported,

  /// Supported, but the model asset is not installed yet.
  needsDownload,

  /// Installed — dictation can start.
  ready,
}

/// One update from a live engine: a volatile draft, or the final words for
/// that stretch of audio.
class LiveResult {
  const LiveResult(this.text, {required this.isFinal});

  final String text;
  final bool isFinal;

  @override
  bool operator ==(Object other) =>
      other is LiveResult && other.text == text && other.isFinal == isFinal;

  @override
  int get hashCode => Object.hash(text, isFinal);

  @override
  String toString() => "LiveResult('$text', isFinal: $isFinal)";
}

/// The live engine seam (Apple SpeechTranscriber, iOS 26): words stream in on
/// [results] while the mic is open — no audio file exists on this path.
abstract class LiveVoiceTranscriber {
  Future<LiveSupport> liveSupport();

  /// True when Speech authorization is granted or not required.
  Future<bool> requestSpeechAuthorization();

  /// Installs the model asset, emitting progress fractions `0.0–1.0`.
  /// Completes when installed; errors with
  /// `VoiceError(VoiceErrorKind.assetDownloadFailed)` on failure. Cancelling
  /// the subscription only detaches Dart — the native download may continue.
  Stream<double> downloadAsset();

  /// Broadcast.
  Stream<LiveResult> get results;

  /// Throws `VoiceError(VoiceErrorKind.recordingFailed)` on failure.
  Future<void> startLive();

  /// Finalizes. Resolves only **after** the last final result has been
  /// emitted on [results].
  Future<void> stopLive();

  /// Tears down; nothing more is emitted.
  Future<void> cancelLive();

  /// Same signature as [VoiceTranscriber.onInterrupted], so one fake can
  /// implement both.
  void onInterrupted(void Function() handler);
}

/// Which engine dictation uses, plus the build check that gates the
/// debug/TestFlight engine pull-down.
abstract class VoiceEngineSettings {
  /// [VoiceEngine.apple] when nothing (or an unknown value) is stored.
  Future<VoiceEngine> enginePreference();

  Future<void> setEnginePreference(VoiceEngine engine);

  Future<bool> isTestFlight();
}
