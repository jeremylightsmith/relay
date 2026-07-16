import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_transcriber.dart';

/// idle → priming → recording → transcribing → review → (Use this | Cancel)
/// with error reachable from recording/transcribing, per the spec's U3 diagram.
/// `starting` is the one-frame permission check before the first real state;
/// `dismissed` tells the sheet to pop with null.
enum VoiceStage {
  starting,
  priming,
  recording,
  transcribing,
  review,
  error,
  dismissed,
}

/// The state machine (spec U3): pure Dart over a [VoiceTranscriber], no
/// widgets — the whole flow unit-tests with FakeVoiceTranscriber and fakeAsync.
class VoiceController extends ChangeNotifier {
  // The public parameter is named `tick` (spec's exact signature); `_tick` is
  // the private field, so an initializing formal isn't available here.
  VoiceController(
    this._transcriber, {
    Duration tick = const Duration(seconds: 1),
    // ignore: prefer_initializing_formals
  }) : _tick = tick {
    _transcriber.onInterrupted(_handleInterruption);
  }

  final VoiceTranscriber _transcriber;
  final Duration _tick;

  VoiceStage stage = VoiceStage.starting;

  /// Counts up with no cap (D8) — the visible cost of a long clip.
  Duration elapsed = Duration.zero;

  String transcript = '';
  String? errorMessage;
  bool showOpenSettings = false;
  bool showTryAgain = false;

  Timer? _timer;
  bool _disposed = false;

  Future<void> start() async {
    switch (await _transcriber.permissionStatus()) {
      case MicPermission.granted:
        await _beginRecording();
      case MicPermission.notDetermined:
        _set(VoiceStage.priming);
      case MicPermission.denied:
        // Previously denied: one line + Open Settings; Type instead is always
        // present (spec error table).
        errorMessage = 'Microphone access is off for Relay.';
        showOpenSettings = true;
        showTryAgain = false;
        _set(VoiceStage.error);
    }
  }

  /// From priming: spend the one-shot OS prompt. Denial dismisses the sheet —
  /// the field behind it stays focused for typing; no nag (spec error table).
  Future<void> allowMic() async {
    if (await _transcriber.requestPermission() == MicPermission.granted) {
      await _beginRecording();
    } else {
      _set(VoiceStage.dismissed);
    }
  }

  Future<void> stopAndReview() async {
    if (stage != VoiceStage.recording) return;
    _stopTimer();
    _set(VoiceStage.transcribing);
    try {
      final text = (await _transcriber.stopAndTranscribe()).trim();
      if (stage != VoiceStage.transcribing) return; // cancelled mid-flight
      if (text.isEmpty) {
        // Silent/empty audio never opens a review sheet (spec error table).
        _fail(VoiceErrorKind.transcriptionFailed);
      } else {
        transcript = text;
        _set(VoiceStage.review);
      }
    } on VoiceError catch (e) {
      if (stage == VoiceStage.transcribing) _fail(e.kind);
    } on Object {
      if (stage == VoiceStage.transcribing) {
        _fail(VoiceErrorKind.transcriptionFailed);
      }
    }
  }

  Future<void> tryAgain() => _beginRecording();

  Future<void> openSettings() => _transcriber.openSettings();

  /// Cancel from any stage; the sheet pops with null when [stage] becomes
  /// [VoiceStage.dismissed].
  Future<void> cancel() async {
    final was = stage;
    _stopTimer();
    _set(VoiceStage.dismissed);
    switch (was) {
      case VoiceStage.recording:
        await _transcriber.cancelRecording();
      case VoiceStage.transcribing:
        await _transcriber.cancelTranscription();
      default:
        break;
    }
  }

  Future<void> _beginRecording() async {
    try {
      await _transcriber.startRecording();
    } on Object {
      _fail(VoiceErrorKind.recordingFailed);
      return;
    }
    elapsed = Duration.zero;
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) {
      elapsed += _tick;
      if (!_disposed) notifyListeners();
    });
    _set(VoiceStage.recording);
  }

  /// A phone call or route change: whatever was captured transcribes rather
  /// than being thrown away (spec error table).
  void _handleInterruption() {
    if (stage == VoiceStage.recording) unawaited(stopAndReview());
  }

  void _fail(VoiceErrorKind kind) {
    errorMessage = switch (kind) {
      VoiceErrorKind.modelUnavailable => "Voice isn't available right now.",
      _ => "Didn't catch that.",
    };
    showOpenSettings = false;
    showTryAgain = true;
    _set(VoiceStage.error);
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _set(VoiceStage next) {
    stage = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimer();
    super.dispose();
  }
}
