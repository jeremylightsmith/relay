import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/apple_speech_transcriber.dart';
import 'package:relay_mobile/features/voice/voice_engine_settings.dart';
import 'package:relay_mobile/features/voice/voice_engines.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';
import 'package:relay_mobile/features/voice/whisper_kit_transcriber.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> log;

  /// Scripts the native side of `relay/voice`. An Exception result is thrown.
  void mockNative(Object? Function(MethodCall call) answer) {
    log = [];
    messenger.setMockMethodCallHandler(IosVoiceEngineSettings.channel, (
      call,
    ) async {
      log.add(call);
      final value = answer(call);
      if (value is Exception) throw value;
      return value;
    });
  }

  tearDown(
    () => messenger.setMockMethodCallHandler(
      IosVoiceEngineSettings.channel,
      null,
    ),
  );

  test('the stored engine maps by name; nothing or nonsense is apple '
      '(scenario 9)', () async {
    final answers = <Object?>['whisper', null, 'nonsense'];
    mockNative(
      (call) => call.method == 'enginePreference' ? answers.removeAt(0) : null,
    );
    final settings = IosVoiceEngineSettings();

    expect(await settings.enginePreference(), VoiceEngine.whisper);
    expect(await settings.enginePreference(), VoiceEngine.apple);
    expect(await settings.enginePreference(), VoiceEngine.apple);
  });

  test('setEnginePreference sends the engine name (scenario 10)', () async {
    mockNative((_) => null);

    await IosVoiceEngineSettings().setEnginePreference(VoiceEngine.whisper);

    expect(log.single.method, 'setEnginePreference');
    expect(log.single.arguments, {'engine': 'whisper'});
  });

  test('isTestFlight passes native true through (scenario 11)', () async {
    mockNative((call) => call.method == 'isTestFlight' ? true : null);

    expect(await IosVoiceEngineSettings().isTestFlight(), isTrue);
  });

  test('isTestFlight is false when the plugin is missing — the check never '
      'blocks dictation (scenario 11)', () async {
    mockNative(
      (call) => call.method == 'isTestFlight'
          ? MissingPluginException('no voice plugin')
          : null,
    );

    expect(await IosVoiceEngineSettings().isTestFlight(), isFalse);
  });

  test('VoiceEngines.platform bundles the real engines and settings', () {
    final engines = VoiceEngines.platform();

    expect(engines.whisper, isA<WhisperKitTranscriber>());
    expect(engines.apple, isA<AppleSpeechTranscriber>());
    expect(engines.settings, isA<IosVoiceEngineSettings>());
  });
}
