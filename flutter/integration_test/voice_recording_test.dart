import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';
import 'package:relay_mobile/features/voice/whisper_kit_transcriber.dart';

/// Drives the REAL WhisperKitTranscriber → relay/voice → VoicePlugin.swift
/// path on the iOS simulator — no FakeVoiceTranscriber anywhere. This is the
/// path every unit test and the Code-stage smoke faked out, which is exactly
/// where the RLY-99 TestFlight crash lived: AVAudioFile.write(from:) raising
/// an uncatchable NSException on a processing-format mismatch, killing the
/// app on the first captured buffer.
///
/// Needs a booted simulator with the mic pre-granted:
///   xcrun simctl privacy booted grant microphone com.jeremylightsmith.Relay
/// Run with:
///   flutter test integration_test/voice_recording_test.dart -d `<simulator>`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real native recording records, stops, and transcribes without crashing',
    (tester) async {
      final transcriber = WhisperKitTranscriber();

      expect(
        await transcriber.permissionStatus(),
        MicPermission.granted,
        reason:
            'Pre-grant the simulator mic first:\n'
            '  xcrun simctl privacy booted grant microphone '
            'com.jeremylightsmith.Relay',
      );

      await transcriber.startRecording();
      // Let real buffers flow through the AVAudioEngine tap → converter →
      // AVAudioFile write. The crash fired on the FIRST buffer write; three
      // seconds is thousands of buffers.
      await Future<void>.delayed(const Duration(seconds: 3));

      // First use lazily loads the bundled ~147MB base.en model — slow on
      // the simulator (CPU, no ANE); allow minutes.
      final text = await transcriber.stopAndTranscribe().timeout(
        const Duration(minutes: 5),
      );

      // Ambient Mac-mic audio may transcribe to anything, including ''.
      // Surviving to ANY string is the regression assertion: before the fix
      // the whole app dies inside the audio tap, long before this returns.
      // A VoiceError here also fails the test — modelUnavailable would mean
      // the bundled model/tokenizer broke, which must be equally loud.
      expect(text, isA<String>());
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
