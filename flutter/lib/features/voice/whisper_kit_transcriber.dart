import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_transcriber.dart';

/// The real engine (spec U2): drives the `relay/voice` channel implemented by
/// ios/Runner/VoicePlugin.swift. Dart owns the audio file's lifecycle — the
/// native side hands back a path, and every path through stop/cancel ends in
/// `deleteRecording`. That is the privacy promise, and it is pinned as a test
/// (test/whisper_kit_transcriber_test.dart), not a comment.
class WhisperKitTranscriber implements VoiceTranscriber {
  WhisperKitTranscriber() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onInterrupted') _interruptionHandler?.call();
    });
  }

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('relay/voice');

  void Function()? _interruptionHandler;

  @override
  Future<MicPermission> permissionStatus() async => _permissionFromName(
    await channel.invokeMethod<String>('permissionStatus'),
  );

  @override
  Future<MicPermission> requestPermission() async => _permissionFromName(
    await channel.invokeMethod<String>('requestPermission'),
  );

  @override
  Future<void> startRecording() async {
    try {
      await channel.invokeMethod<void>('startRecording');
    } on PlatformException {
      throw const VoiceError(VoiceErrorKind.recordingFailed);
    }
  }

  @override
  Future<void> cancelRecording() async {
    final path = await channel.invokeMethod<String>('cancelRecording');
    if (path != null) await _delete(path);
  }

  @override
  Future<String> stopAndTranscribe() async {
    final path = await channel.invokeMethod<String>('stopRecording');
    if (path == null) throw const VoiceError(VoiceErrorKind.recordingFailed);
    try {
      final text = await channel.invokeMethod<String>('transcribe', {
        'path': path,
      });
      return text ?? '';
    } on PlatformException catch (e) {
      throw VoiceError(
        e.code == 'model_load_failed'
            ? VoiceErrorKind.modelUnavailable
            : VoiceErrorKind.transcriptionFailed,
      );
    } finally {
      await _delete(path);
    }
  }

  @override
  Future<void> cancelTranscription() =>
      channel.invokeMethod<void>('cancelTranscription');

  @override
  void onInterrupted(void Function() handler) => _interruptionHandler = handler;

  @override
  Future<void> openSettings() => channel.invokeMethod<void>('openSettings');

  /// Deletion must never mask the transcript or the real error.
  Future<void> _delete(String path) async {
    try {
      await channel.invokeMethod<void>('deleteRecording', {'path': path});
    } on PlatformException {
      // The native delete is idempotent; a failure here has nothing actionable.
    }
  }

  MicPermission _permissionFromName(String? name) => switch (name) {
    'notDetermined' => MicPermission.notDetermined,
    'denied' => MicPermission.denied,
    'granted' => MicPermission.granted,
    _ => throw StateError('unknown mic permission: $name'),
  };
}
