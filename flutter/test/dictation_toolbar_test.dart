import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/voice/dictation_controller.dart';
import 'package:relay_mobile/features/voice/dictation_text_controller.dart';
import 'package:relay_mobile/features/voice/dictation_toolbar.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

import 'support/fake_voice_transcriber.dart';

/// The storybook-equivalent for [DictationToolbar] (RE467): one test per
/// state, each over a real [DictationController] driven by the fake engines.
Future<DictationController> _pump(
  WidgetTester tester,
  FakeVoiceTranscriber fake, {
  bool debugBuild = true,
}) async {
  final field = DictationTextController();
  final controller = DictationController(
    fake.engines,
    field: field,
    debugBuild: debugBuild,
  );
  addTearDown(field.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: DictationToolbar(controller: controller),
        ),
      ),
    ),
  );
  return controller;
}

/// Ends a test: unmounts the toolbar and disposes [controller] inside the test
/// body, so its ticking timer is cancelled before the pending-timer check.
Future<void> _end(WidgetTester tester, DictationController controller) async {
  await tester.pumpWidget(const SizedBox());
  controller.dispose();
}

/// Starts dictation and lets the fake's async answers settle.
Future<void> _start(WidgetTester tester, DictationController controller) async {
  controller.toggle();
  await tester.pump();
  await tester.pump();
}

Finder _key(String key) => find.byKey(Key(key));

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data!;

void main() {
  testWidgets('1 · listening: waveform, m:ss timer, engine label, red stop', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    final controller = await _pump(tester, fake);
    await _start(tester, controller);
    await tester.pump(const Duration(seconds: 14));

    expect(controller.stage, DictationStage.listening);
    expect(_key('dictation_listening'), findsOneWidget);
    expect(_text(tester, 'dictation_timer'), '0:14');

    final bars = find.descendant(
      of: _key('dictation_waveform'),
      matching: find.byType(AnimatedContainer),
    );
    expect(bars, findsNWidgets(22));
    for (final element in bars.evaluate()) {
      expect(element.size!.width, 3);
    }

    expect(
      find.descendant(
        of: _key('dictation_engine_label'),
        matching: find.text('Apple'),
      ),
      findsOneWidget,
    );

    expect(tester.getSize(_key('dictation_stop')), const Size(30, 30));
    final stop = tester.widget<Container>(_key('dictation_stop'));
    expect(
      (stop.decoration! as BoxDecoration).color,
      RelayTheme.relayDictationStop,
    );

    final bar = tester.widget<Container>(_key('dictation_toolbar'));
    final deco = bar.decoration! as BoxDecoration;
    expect(deco.color, RelayTheme.relayDictationToolbarBg);
    expect(
      deco.border,
      const Border(top: BorderSide(color: RelayTheme.relayHairline)),
    );

    await _end(tester, controller);
  });

  testWidgets('2 · App Store build: no engine label', (tester) async {
    final fake = FakeVoiceTranscriber(testFlight: false);
    final controller = await _pump(tester, fake, debugBuild: false);
    await _start(tester, controller);

    expect(controller.stage, DictationStage.listening);
    expect(_key('dictation_listening'), findsOneWidget);
    expect(_key('dictation_engine_label'), findsNothing);

    await _end(tester, controller);
  });

  testWidgets('3 · transcribing: spinner and copy, no stop', (tester) async {
    final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper)
      ..holdTranscription = true;
    final controller = await _pump(tester, fake);
    await _start(tester, controller);
    controller.stop();
    await tester.pump();

    expect(controller.stage, DictationStage.transcribing);
    expect(
      find.descendant(
        of: _key('dictation_transcribing'),
        matching: find.text('Transcribing…'),
      ),
      findsOneWidget,
    );
    expect(_key('dictation_stop'), findsNothing);

    fake.completeTranscription();
    await tester.pump();

    await _end(tester, controller);
  });

  testWidgets('4 · downloading: ring, percent, Use Whisper now, Keep typing', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(support: LiveSupport.needsDownload);
    final controller = await _pump(tester, fake);
    await _start(tester, controller);
    fake.emitProgress(0.62);
    await tester.pump();
    await tester.pump();

    expect(_key('dictation_downloading'), findsOneWidget);
    expect(find.text('Downloading Apple dictation…'), findsOneWidget);
    expect(_text(tester, 'dictation_download_percent'), '62%');
    expect(find.text('One time only · about a minute'), findsOneWidget);
    final ring = tester.widget<CircularProgressIndicator>(
      _key('dictation_download_ring'),
    );
    expect(ring.value, 0.62);
    expect(
      find.descendant(
        of: _key('dictation_use_whisper'),
        matching: find.text('Use Whisper now'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('dictation_keep_typing'),
        matching: find.text('Keep typing'),
      ),
      findsOneWidget,
    );

    await tester.tap(_key('dictation_keep_typing'));
    await tester.pump();
    expect(controller.stage, DictationStage.idle);

    await _end(tester, controller);
  });

  testWidgets('5 · priming: the RLY-99 copy, Allow microphone, Not now', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(status: MicPermission.notDetermined);
    final controller = await _pump(tester, fake);
    await _start(tester, controller);

    final priming = _key('dictation_priming');
    expect(priming, findsOneWidget);
    expect(
      find.descendant(
        of: priming,
        matching: find.text('Dictate instead of typing'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: priming,
        matching: find.textContaining('audio never leaves it'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: priming, matching: find.text('Allow microphone')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: priming, matching: find.text('Not now')),
      findsOneWidget,
    );

    await tester.tap(_key('dictation_not_now'));
    await tester.pump();
    expect(controller.stage, DictationStage.idle);

    await _end(tester, controller);
  });

  testWidgets('6 · denied: Open Settings, no Try again', (tester) async {
    final fake = FakeVoiceTranscriber(status: MicPermission.denied);
    final controller = await _pump(tester, fake);
    await _start(tester, controller);

    expect(_key('dictation_error'), findsOneWidget);
    expect(
      _text(tester, 'dictation_error_message'),
      'Microphone access is off for Relay.',
    );
    expect(_key('dictation_open_settings'), findsOneWidget);
    expect(_key('dictation_try_again'), findsNothing);

    await tester.tap(_key('dictation_open_settings'));
    await tester.pump();
    expect(fake.openSettingsCount, 1);

    await _end(tester, controller);
  });

  testWidgets('7 · failure: Didn\'t catch that, Try again, Type instead', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(
      preference: VoiceEngine.whisper,
      transcript: '',
    );
    final controller = await _pump(tester, fake);
    await _start(tester, controller);
    controller.stop();
    await tester.pump();
    await tester.pump();

    expect(controller.stage, DictationStage.error);
    expect(find.text("Didn't catch that."), findsOneWidget);
    expect(_key('dictation_try_again'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('dictation_dismiss'),
        matching: find.text('Type instead'),
      ),
      findsOneWidget,
    );

    await tester.tap(_key('dictation_dismiss'));
    await tester.pump();
    expect(controller.stage, DictationStage.idle);

    await _end(tester, controller);
  });

  testWidgets('8 · the engine pull-down switches Apple → Whisper', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    final controller = await _pump(tester, fake);
    await _start(tester, controller);

    await tester.tap(_key('dictation_engine_label'));
    await tester.pumpAndSettle();

    expect(_key('dictation_engine_apple'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('dictation_engine_apple'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    expect(_key('dictation_engine_whisper'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('dictation_engine_whisper'),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
    expect(
      _text(tester, 'dictation_engine_footnote'),
      'Debug & TestFlight builds only',
    );

    await tester.tap(_key('dictation_engine_whisper'));
    await tester.pumpAndSettle();

    expect(fake.setPreferenceCalls, [VoiceEngine.whisper]);
    expect(controller.activeEngine, VoiceEngine.whisper);

    await _end(tester, controller);
  });
}
