import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';
import 'package:relay_mobile/features/voice/whisper_kit_transcriber.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const path = '/tmp/relay-voice-test.wav';
  late List<MethodCall> log;

  /// Scripts the native side of `relay/voice`.
  void mockNative({Object? Function(MethodCall call)? overrides}) {
    log = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WhisperKitTranscriber.channel, (call) async {
          log.add(call);
          final override = overrides?.call(call);
          if (override is Exception) throw override;
          if (override != null) return override;
          return switch (call.method) {
            'stopRecording' || 'cancelRecording' => path,
            'transcribe' => 'use the EU region',
            'permissionStatus' || 'requestPermission' => 'granted',
            _ => null,
          };
        });
  }

  List<String> methods() => log.map((c) => c.method).toList();

  group('recorded audio does not outlive the sheet (criterion 10)', () {
    test('the file is deleted after a successful transcription', () async {
      mockNative();
      final text = await WhisperKitTranscriber().stopAndTranscribe();

      expect(text, 'use the EU region');
      expect(methods(), ['stopRecording', 'transcribe', 'deleteRecording']);
      expect(log.last.arguments, {'path': path});
    });

    test('the file is deleted even when transcription fails', () async {
      mockNative(
        overrides: (call) => call.method == 'transcribe'
            ? PlatformException(code: 'transcribe_failed')
            : null,
      );

      await expectLater(
        WhisperKitTranscriber().stopAndTranscribe(),
        throwsA(
          isA<VoiceError>().having(
            (e) => e.kind,
            'kind',
            VoiceErrorKind.transcriptionFailed,
          ),
        ),
      );
      expect(methods(), contains('deleteRecording'));
    });

    test('the file is deleted after cancellation', () async {
      mockNative();
      await WhisperKitTranscriber().cancelRecording();

      expect(methods(), ['cancelRecording', 'deleteRecording']);
      expect(log.last.arguments, {'path': path});
    });

    test('no delete call when cancel finds no recording', () async {
      log = [];
      // Script the native side returning null for everything — no file existed.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WhisperKitTranscriber.channel, (
            call,
          ) async {
            log.add(call);
            return null;
          });

      await WhisperKitTranscriber().cancelRecording();
      expect(methods(), ['cancelRecording']);
    });

    test('a failing delete never masks the transcript', () async {
      mockNative(
        overrides: (call) => call.method == 'deleteRecording'
            ? PlatformException(code: 'delete_failed')
            : null,
      );

      expect(
        await WhisperKitTranscriber().stopAndTranscribe(),
        'use the EU region',
      );
    });
  });

  group('error classification', () {
    test('model_load_failed → modelUnavailable', () async {
      mockNative(
        overrides: (call) => call.method == 'transcribe'
            ? PlatformException(code: 'model_load_failed')
            : null,
      );

      await expectLater(
        WhisperKitTranscriber().stopAndTranscribe(),
        throwsA(
          isA<VoiceError>().having(
            (e) => e.kind,
            'kind',
            VoiceErrorKind.modelUnavailable,
          ),
        ),
      );
    });

    test('startRecording failure → recordingFailed', () async {
      mockNative(
        overrides: (call) => call.method == 'startRecording'
            ? PlatformException(code: 'recording_failed')
            : null,
      );

      await expectLater(
        WhisperKitTranscriber().startRecording(),
        throwsA(
          isA<VoiceError>().having(
            (e) => e.kind,
            'kind',
            VoiceErrorKind.recordingFailed,
          ),
        ),
      );
    });

    test('permission names map; an unknown name throws', () async {
      mockNative();
      expect(
        await WhisperKitTranscriber().permissionStatus(),
        MicPermission.granted,
      );

      mockNative(
        overrides: (call) =>
            call.method == 'permissionStatus' ? 'sideways' : null,
      );
      await expectLater(
        WhisperKitTranscriber().permissionStatus(),
        throwsStateError,
      );
    });
  });
}
