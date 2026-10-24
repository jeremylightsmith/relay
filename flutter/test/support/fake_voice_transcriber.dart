import 'dart:async';

import 'package:relay_mobile/features/voice/voice_engines.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

/// A fake for every voice seam — the Whisper batch engine, the Apple live
/// engine and the engine settings — so [engines] can stand in for
/// `VoiceEngines.platform()`. No MethodChannel, no OS. The repo has no mocking
/// package; seams are structural (see FakePushPlatform).
class FakeVoiceTranscriber
    implements VoiceTranscriber, LiveVoiceTranscriber, VoiceEngineSettings {
  FakeVoiceTranscriber({
    this.status = MicPermission.granted,
    this.statusAfterRequest = MicPermission.granted,
    this.transcript = 'Yes, publish, but fix the second one.',
    this.startError,
    this.stopError,
    this.support = LiveSupport.ready,
    this.speechAuthorized = true,
    this.preference = VoiceEngine.apple,
    this.testFlight = false,
    this.liveStartError,
  });

  /// Whisper, Apple and settings, all backed by this one fake.
  VoiceEngines get engines =>
      VoiceEngines(whisper: this, apple: this, settings: this);

  MicPermission status;
  MicPermission statusAfterRequest;
  String transcript;

  /// When set, startRecording / stopAndTranscribe throw these instead.
  Object? startError;
  Object? stopError;

  /// When true, stopAndTranscribe stays pending until [completeTranscription] —
  /// how tests hold the transcribing state open.
  bool holdTranscription = false;
  Completer<String>? _pending;

  int statusCount = 0;
  int requestCount = 0;
  int startCount = 0;
  int cancelRecordingCount = 0;
  int stopCount = 0;
  int cancelTranscriptionCount = 0;
  int openSettingsCount = 0;
  void Function()? interruptionHandler;

  @override
  Future<MicPermission> permissionStatus() async {
    statusCount++;
    return status;
  }

  @override
  Future<MicPermission> requestPermission() async {
    requestCount++;
    return statusAfterRequest;
  }

  @override
  Future<void> startRecording() async {
    startCount++;
    if (startError != null) throw startError!;
  }

  @override
  Future<void> cancelRecording() async {
    cancelRecordingCount++;
    if (holdCancelRecording) {
      _pendingCancel = Completer<void>();
      await _pendingCancel!.future;
    }
  }

  /// When true, cancelRecording stays pending until [completeCancelRecording].
  bool holdCancelRecording = false;
  Completer<void>? _pendingCancel;

  void completeCancelRecording() => _pendingCancel!.complete();

  @override
  Future<String> stopAndTranscribe() {
    stopCount++;
    if (stopError != null) return Future.error(stopError!);
    if (holdTranscription) {
      _pending = Completer<String>();
      return _pending!.future;
    }
    return Future.value(transcript);
  }

  void completeTranscription([String? text]) =>
      _pending!.complete(text ?? transcript);

  @override
  Future<void> cancelTranscription() async => cancelTranscriptionCount++;

  /// Both seams register here; whichever registration came last wins (the
  /// controller registers one handler for both).
  @override
  void onInterrupted(void Function() handler) => interruptionHandler = handler;

  /// Simulates the OS interrupting an active recording or live session.
  void interrupt() => interruptionHandler?.call();

  @override
  Future<void> openSettings() async => openSettingsCount++;

  // --- LiveVoiceTranscriber (Apple) ---

  LiveSupport support;
  bool speechAuthorized;

  /// When set, startLive throws this instead.
  Object? liveStartError;

  /// Emitted on [results] inside stopLive(), before it resolves — the final
  /// words a real finalize flushes.
  List<LiveResult> resultsOnStop = [];

  /// When true, stopLive stays pending until [completeLiveStop].
  bool holdLiveStop = false;
  Completer<void>? _pendingStop;

  /// When true, startLive stays pending until [completeLiveStart].
  bool holdLiveStart = false;
  Completer<void>? _pendingStart;

  StreamController<double>? _download;

  int liveSupportCount = 0;
  int speechRequestCount = 0;
  int downloadCount = 0;
  int liveStartCount = 0;
  int liveStopCount = 0;
  int liveCancelCount = 0;

  // Sync, so "stopLive resolved ⇒ every final already emitted" holds exactly.
  final _results = StreamController<LiveResult>.broadcast(sync: true);

  @override
  Stream<LiveResult> get results => _results.stream;

  /// Pushes a draft (or, with [isFinal], final) result onto [results].
  void emitResult(String text, {bool isFinal = false}) =>
      _results.add(LiveResult(text, isFinal: isFinal));

  @override
  Future<LiveSupport> liveSupport() async {
    liveSupportCount++;
    return support;
  }

  @override
  Future<bool> requestSpeechAuthorization() async {
    speechRequestCount++;
    return speechAuthorized;
  }

  /// Driven by [emitProgress], [completeDownload] and [failDownload].
  @override
  Stream<double> downloadAsset() {
    downloadCount++;
    _download = StreamController<double>();
    return _download!.stream;
  }

  void emitProgress(double fraction) => _download!.add(fraction);

  void completeDownload() => _download!.close();

  void failDownload() {
    _download!.addError(const VoiceError(VoiceErrorKind.assetDownloadFailed));
    _download!.close();
  }

  @override
  Future<void> startLive() async {
    liveStartCount++;
    if (holdLiveStart) {
      _pendingStart = Completer<void>();
      await _pendingStart!.future;
    }
    if (liveStartError != null) throw liveStartError!;
  }

  void completeLiveStart() => _pendingStart!.complete();

  @override
  Future<void> stopLive() async {
    liveStopCount++;
    if (holdLiveStop) {
      _pendingStop = Completer<void>();
      await _pendingStop!.future;
    }
    for (final result in resultsOnStop) {
      _results.add(result);
    }
  }

  void completeLiveStop() => _pendingStop!.complete();

  @override
  Future<void> cancelLive() async => liveCancelCount++;

  // --- VoiceEngineSettings ---

  VoiceEngine preference;
  bool testFlight;
  final List<VoiceEngine> setPreferenceCalls = [];

  @override
  Future<VoiceEngine> enginePreference() async => preference;

  @override
  Future<void> setEnginePreference(VoiceEngine engine) async {
    setPreferenceCalls.add(engine);
    preference = engine;
  }

  @override
  Future<bool> isTestFlight() async => testFlight;
}
