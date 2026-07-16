import 'dart:async';

import 'package:relay_mobile/features/voice/voice_transcriber.dart';

/// A fake VoiceTranscriber — no MethodChannel, no OS. The repo has no mocking
/// package; seams are structural (see FakePushPlatform).
class FakeVoiceTranscriber implements VoiceTranscriber {
  FakeVoiceTranscriber({
    this.status = MicPermission.granted,
    this.statusAfterRequest = MicPermission.granted,
    this.transcript = 'Yes, publish, but fix the second one.',
    this.startError,
    this.stopError,
  });

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
  Future<void> cancelRecording() async => cancelRecordingCount++;

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

  @override
  void onInterrupted(void Function() handler) => interruptionHandler = handler;

  /// Simulates the OS interrupting an active recording.
  void interrupt() => interruptionHandler?.call();

  @override
  Future<void> openSettings() async => openSettingsCount++;
}
