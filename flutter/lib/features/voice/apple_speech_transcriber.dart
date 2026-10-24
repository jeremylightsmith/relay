import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_transcriber.dart';

/// Apple's live engine (iOS 26 SpeechAnalyzer + SpeechTranscriber), driven by
/// ios/Runner/VoicePlugin.swift. Words stream in while the mic is open; no
/// audio file is ever written on this path, so there is nothing to delete.
///
/// Calls go out on `relay/voice` — **invoke-only**. Never call
/// setMethodCallHandler here: a channel has exactly one handler, and
/// WhisperKitTranscriber's owns `onInterrupted` for Whisper recordings. A
/// second one would silently steal it. Everything native pushes to *this*
/// engine (results, download progress, live interruptions) arrives on the
/// `relay/voice/events` EventChannel instead.
class AppleSpeechTranscriber implements LiveVoiceTranscriber {
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('relay/voice');

  @visibleForTesting
  static const EventChannel events = EventChannel('relay/voice/events');

  // The wire contract — mirrored once in VoicePlugin.swift.
  static const _liveSupport = 'liveSupport';
  static const _requestSpeechPermission = 'requestSpeechPermission';
  static const _downloadAsset = 'downloadAsset';
  static const _startLive = 'startLive';
  static const _stopLive = 'stopLive';
  static const _cancelLive = 'cancelLive';
  static const _granted = 'granted';
  static const _eventResult = 'result';
  static const _eventProgress = 'progress';
  static const _eventInterrupted = 'interrupted';

  static const _downloadFailed = VoiceError(VoiceErrorKind.assetDownloadFailed);

  final _results = StreamController<LiveResult>.broadcast(sync: true);
  StreamSubscription<dynamic>? _events;
  StreamController<double>? _download;
  void Function()? _interruptionHandler;

  /// Never throws: a channel failure (or no native side at all) reads as
  /// unsupported, which keeps dictation on Whisper.
  @override
  Future<LiveSupport> liveSupport() async {
    final String? name;
    try {
      name = await channel.invokeMethod<String>(_liveSupport);
    } on PlatformException {
      return LiveSupport.unsupported;
    } on MissingPluginException {
      return LiveSupport.unsupported;
    }
    return LiveSupport.values.firstWhere(
      (s) => s.name == name,
      orElse: () => LiveSupport.unsupported,
    );
  }

  @override
  Future<bool> requestSpeechAuthorization() async =>
      await channel.invokeMethod<String>(_requestSpeechPermission) == _granted;

  @override
  Stream<double> downloadAsset() {
    late final StreamController<double> controller;
    controller = StreamController<double>(
      onListen: () async {
        _subscribe();
        _download = controller;
        try {
          await channel.invokeMethod<void>(_downloadAsset);
        } on PlatformException {
          controller.addError(_downloadFailed);
        } on MissingPluginException {
          // No native side: error the stream rather than leak an uncaught
          // error out of this async onListen.
          controller.addError(_downloadFailed);
        } finally {
          // Native sends its last progress events just before the reply; they
          // travel a different channel, so let them land before closing.
          await Future<void>.delayed(Duration.zero);
          if (identical(_download, controller)) _download = null;
          await controller.close();
        }
      },
      // Detaches Dart only; the native download carries on.
      onCancel: () {
        if (identical(_download, controller)) _download = null;
      },
    );
    return controller.stream;
  }

  @override
  Stream<LiveResult> get results => _results.stream;

  @override
  Future<void> startLive() async {
    _subscribe();
    try {
      await channel.invokeMethod<void>(_startLive);
    } on PlatformException {
      // `recording_failed`, or `unsupported` below iOS 26 — either way the mic
      // never opened.
      throw const VoiceError(VoiceErrorKind.recordingFailed);
    }
  }

  @override
  Future<void> stopLive() => channel.invokeMethod<void>(_stopLive);

  @override
  Future<void> cancelLive() => channel.invokeMethod<void>(_cancelLive);

  @override
  void onInterrupted(void Function() handler) {
    _interruptionHandler = handler;
    _subscribe();
  }

  /// Lazy and once: an EventChannel has a single native listener, and an
  /// eager subscription would log MissingPluginException in every widget test
  /// that builds a host with no native side.
  void _subscribe() =>
      _events ??= events.receiveBroadcastStream().listen(_onEvent);

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['type']) {
      case _eventResult:
        _results.add(
          LiveResult(
            event['text'] as String? ?? '',
            isFinal: event['isFinal'] as bool? ?? false,
          ),
        );
      case _eventProgress:
        final fraction = event['fraction'];
        if (fraction is num) _download?.add(fraction.toDouble());
      case _eventInterrupted:
        _interruptionHandler?.call();
    }
    // Unknown types are ignored.
  }
}
