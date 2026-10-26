import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/dictation_controller.dart';
import 'package:relay_mobile/features/voice/dictation_text_controller.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

import 'support/fake_voice_transcriber.dart';

/// A controller over [fake] and [field], recording every onInserted payload.
class _Rig {
  _Rig(this.fake, {String text = '', int? caret, bool debugBuild = true})
    : field = DictationTextController(text: text) {
    if (caret != null) {
      field.selection = TextSelection.collapsed(offset: caret);
    }
    controller = DictationController(
      fake.engines,
      field: field,
      onInserted: inserted.add,
      debugBuild: debugBuild,
    );
  }

  final FakeVoiceTranscriber fake;
  final DictationTextController field;
  late final DictationController controller;
  final List<String> inserted = [];

  /// Simulates the user typing: text and caret change together.
  void type(String text, int caret) => field.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
  );

  void moveCaret(int offset) => field.value = field.value.copyWith(
    selection: TextSelection.collapsed(offset: offset),
  );
}

/// Starts dictation and flushes it into [DictationStage.listening].
_Rig _listening(
  FakeAsync async,
  FakeVoiceTranscriber fake, {
  String text = '',
  int? caret,
  bool debugBuild = true,
}) {
  final rig = _Rig(fake, text: text, caret: caret, debugBuild: debugBuild);
  rig.controller.start();
  async.flushMicrotasks();
  return rig;
}

void main() {
  group('engine selection', () {
    test('debug build, Apple ready and preferred → Apple listening', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = _listening(async, fake).controller;

        expect(c.stage, DictationStage.listening);
        expect(c.activeEngine, VoiceEngine.apple);
        expect(c.showEngineSwitch, isTrue);
        expect(fake.liveStartCount, 1);
        expect(fake.startCount, 0);
        c.dispose();
      });
    });

    test('debug build with Whisper preferred → Whisper', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper);
        final c = _listening(async, fake).controller;

        expect(c.activeEngine, VoiceEngine.whisper);
        expect(fake.startCount, 1);
        expect(fake.liveStartCount, 0);
        c.dispose();
      });
    });

    test('App Store build ignores the stored choice and hides the switch', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper);
        final c = _listening(async, fake, debugBuild: false).controller;

        expect(c.showEngineSwitch, isFalse);
        expect(c.activeEngine, VoiceEngine.apple);
        c.dispose();
      });
    });

    test('TestFlight build shows the switch', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(testFlight: true);
        final c = _listening(async, fake, debugBuild: false).controller;

        expect(c.showEngineSwitch, isTrue);
        c.dispose();
      });
    });

    test('below iOS 26 → Whisper, no switch, no Speech prompt', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(support: LiveSupport.unsupported);
        final c = _listening(async, fake).controller;

        expect(c.activeEngine, VoiceEngine.whisper);
        expect(c.showEngineSwitch, isFalse);
        expect(fake.speechRequestCount, 0);
        c.dispose();
      });
    });

    test('Speech authorization denied falls back to Whisper silently', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(speechAuthorized: false);
        final c = _listening(async, fake).controller;

        expect(c.activeEngine, VoiceEngine.whisper);
        expect(c.stage, DictationStage.listening);
        expect(c.errorMessage, isNull);
        c.dispose();
      });
    });
  });

  group('permission', () {
    test('notDetermined primes; Allow then listens', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(status: MicPermission.notDetermined);
        final c = _listening(async, fake).controller;
        expect(c.stage, DictationStage.priming);

        c.allowMic();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.listening);
        c.dispose();
      });
    });

    test('denial at the OS prompt goes idle — no nag', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          status: MicPermission.notDetermined,
          statusAfterRequest: MicPermission.denied,
        );
        final c = _listening(async, fake).controller;
        c.allowMic();
        async.flushMicrotasks();

        expect(c.stage, DictationStage.idle);
        expect(fake.startCount, 0);
        expect(fake.liveStartCount, 0);
        c.dispose();
      });
    });

    test('previously denied offers Open Settings, not Try again', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(status: MicPermission.denied);
        final c = _listening(async, fake).controller;

        expect(c.stage, DictationStage.error);
        expect(c.errorMessage, 'Microphone access is off for Hamaca.');
        expect(c.showOpenSettings, isTrue);
        expect(c.showTryAgain, isFalse);

        c.openSettings();
        async.flushMicrotasks();
        expect(fake.openSettingsCount, 1);
        c.dispose();
      });
    });
  });

  group('cursor and draft rules (Apple)', () {
    test('a first result lands as a draft in an empty field', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake);

        fake.emitResult('yes publish');

        expect(rig.field.text, 'yes publish');
        expect(rig.field.draft, const TextRange(start: 0, end: 11));
        expect(rig.inserted, ['yes publish']);
        rig.controller.dispose();
      });
    });

    test('a newer volatile result replaces the draft in place', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake);

        fake.emitResult('yes publish');
        fake.emitResult('yes publish it');

        expect(rig.field.text, 'yes publish it');
        expect(rig.field.draft, const TextRange(start: 0, end: 14));
        rig.controller.dispose();
      });
    });

    test('a final becomes ink; the next result starts a new span', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake);

        fake.emitResult('yes publish');
        fake.emitResult('yes publish it');
        fake.emitResult('Yes, publish it.', isFinal: true);

        expect(rig.field.text, 'Yes, publish it.');
        expect(rig.field.draft, isNull);
        expect(rig.field.selection, const TextSelection.collapsed(offset: 16));

        fake.emitResult('Then ship');
        expect(rig.field.text, 'Yes, publish it. Then ship');
        expect(rig.field.draft, const TextRange(start: 16, end: 26));
        rig.controller.dispose();
      });
    });

    test('an edit before the span shifts it', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake, text: 'Fix bug', caret: 7);

        fake.emitResult('today');
        expect(rig.field.text, 'Fix bug today');
        expect(rig.field.draft, const TextRange(start: 7, end: 13));

        rig.type('Fix the bug today', 8);
        expect(rig.field.draft, const TextRange(start: 11, end: 17));

        fake.emitResult('today please', isFinal: true);
        expect(rig.field.text, 'Fix the bug today please');
        expect(rig.field.draft, isNull);
        rig.controller.dispose();
      });
    });

    test('a moved caret starts the next span at the new cursor', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake);
        fake.emitResult('Yes, publish it.', isFinal: true);
        expect(rig.field.draft, isNull);

        rig.moveCaret(4);
        expect(rig.field.text, 'Yes, publish it.');

        fake.emitResult('really');
        expect(rig.field.text, 'Yes, really publish it.');
        expect(rig.field.draft, const TextRange(start: 4, end: 11));
        rig.controller.dispose();
      });
    });

    test('an edit inside the span freezes it and drops results up to the '
        'next final', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake, text: 'Yes, publish ', caret: 13);
        fake.emitResult('it goes to spec');
        expect(rig.field.text, 'Yes, publish it goes to spec');
        expect(rig.field.draft, const TextRange(start: 13, end: 28));

        // Delete the 's' of 'spec'.
        rig.type('Yes, publish it goes to pec', 24);
        expect(rig.field.draft, isNull);
        expect(rig.field.text, 'Yes, publish it goes to pec');

        fake.emitResult('it goes to spec and');
        fake.emitResult('It goes to spec.', isFinal: true);
        expect(rig.field.text, 'Yes, publish it goes to pec');

        fake.emitResult('Next');
        expect(rig.field.text, 'Yes, publish it goes to Next pec');
        rig.controller.dispose();
      });
    });

    test('a selection-only move neither shifts nor freezes the draft', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake, text: 'Fix ', caret: 4);
        fake.emitResult('the bug');

        rig.moveCaret(1);
        expect(rig.field.draft, const TextRange(start: 4, end: 11));

        fake.emitResult('the big bug');
        expect(rig.field.text, 'Fix the big bug');
        expect(rig.field.selection, const TextSelection.collapsed(offset: 1));
        rig.controller.dispose();
      });
    });

    test('an empty final removes the draft', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake, text: 'Fix ', caret: 4);
        fake.emitResult('um');
        expect(rig.field.text, 'Fix um');

        fake.emitResult('', isFinal: true);
        expect(rig.field.text, 'Fix ');
        expect(rig.field.draft, isNull);
        rig.controller.dispose();
      });
    });
  });

  group('stop, timer and interruption', () {
    test('the timer counts while listening and stops on stop', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = _listening(async, fake).controller;

        async.elapse(const Duration(seconds: 14));
        expect(c.elapsed, const Duration(seconds: 14));

        c.stop();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(c.elapsed, const Duration(seconds: 14));
        c.dispose();
      });
    });

    test('Apple stop applies the finalize results and settles the draft', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber()
          ..resultsOnStop = [const LiveResult('go to spec.', isFinal: true)];
        final rig = _listening(async, fake, text: 'Now ', caret: 4);
        fake.emitResult('go to spec');
        expect(rig.field.draft, isNotNull);

        rig.controller.stop();
        async.flushMicrotasks();

        expect(fake.liveStopCount, 1);
        expect(rig.field.text, endsWith('go to spec.'));
        expect(rig.field.draft, isNull);
        expect(rig.controller.stage, DictationStage.idle);
        rig.controller.dispose();
      });
    });

    test('a hung finalize times out; the draft stays as ink', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber()..holdLiveStop = true;
        final rig = _listening(async, fake);
        fake.emitResult('half');

        rig.controller.stop();
        async.elapse(const Duration(seconds: 2));

        expect(rig.controller.stage, DictationStage.idle);
        expect(rig.field.text, contains('half'));
        expect(rig.field.draft, isNull);

        fake.emitResult('half done', isFinal: true);
        expect(rig.field.text, 'half');
        rig.controller.dispose();
      });
    });

    test('Apple silence just closes — no error', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake);

        rig.controller.stop();
        async.flushMicrotasks();

        expect(rig.controller.stage, DictationStage.idle);
        expect(rig.field.text, '');
        expect(rig.controller.errorMessage, isNull);
        rig.controller.dispose();
      });
    });

    test('an interruption stops Apple', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = _listening(async, fake).controller;

        fake.interrupt();
        async.flushMicrotasks();

        expect(fake.liveStopCount, 1);
        expect(c.stage, DictationStage.idle);
        c.dispose();
      });
    });

    test('an interruption stops Whisper', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper);
        final c = _listening(async, fake).controller;

        fake.interrupt();
        async.flushMicrotasks();

        expect(fake.stopCount, 1);
        c.dispose();
      });
    });
  });

  group('Whisper', () {
    test('inserts the transcript at the cursor', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          preference: VoiceEngine.whisper,
          transcript: 'really',
        );
        final rig = _listening(async, fake, text: 'Fix the bug', caret: 3);

        rig.controller.stop();
        async.flushMicrotasks();

        expect(rig.field.text, 'Fix really the bug');
        expect(rig.field.selection, const TextSelection.collapsed(offset: 10));
        expect(rig.inserted, ['Fix really the bug']);
        expect(rig.controller.stage, DictationStage.idle);
        rig.controller.dispose();
      });
    });

    test('holds transcribing until the transcript arrives', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper)
          ..holdTranscription = true;
        final c = _listening(async, fake).controller;

        c.stop();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.transcribing);
        expect(c.isActive, isTrue);

        fake.completeTranscription();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.idle);
        c.dispose();
      });
    });

    test('silence is "Didn\'t catch that." with Try again', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          preference: VoiceEngine.whisper,
          transcript: '   ',
        );
        final c = _listening(async, fake).controller;

        c.stop();
        async.flushMicrotasks();

        expect(c.stage, DictationStage.error);
        expect(c.errorMessage, "Didn't catch that.");
        expect(c.showTryAgain, isTrue);
        c.dispose();
      });
    });

    test('a missing model is "Voice isn\'t available right now."', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          preference: VoiceEngine.whisper,
          stopError: const VoiceError(VoiceErrorKind.modelUnavailable),
        );
        final c = _listening(async, fake).controller;

        c.stop();
        async.flushMicrotasks();

        expect(c.stage, DictationStage.error);
        expect(c.errorMessage, "Voice isn't available right now.");
        c.dispose();
      });
    });
  });

  group('downloading', () {
    test('progress, then Apple listening starts by itself', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(support: LiveSupport.needsDownload);
        final c = _listening(async, fake).controller;
        expect(c.stage, DictationStage.downloading);
        expect(fake.downloadCount, 1);

        fake.emitProgress(0.62);
        async.flushMicrotasks();
        expect(c.downloadProgress, 0.62);

        fake.completeDownload();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.listening);
        expect(c.activeEngine, VoiceEngine.apple);
        expect(fake.liveStartCount, 1);
        c.dispose();
      });
    });

    test('Keep typing goes idle and ignores the finished download', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(support: LiveSupport.needsDownload);
        final c = _listening(async, fake).controller;

        c.keepTyping();
        expect(c.stage, DictationStage.idle);

        fake.completeDownload();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.idle);
        expect(fake.liveStartCount, 0);
        c.dispose();
      });
    });

    test('Use Whisper now records on Whisper without storing the choice', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(support: LiveSupport.needsDownload);
        final c = _listening(async, fake).controller;

        c.useWhisperNow();
        async.flushMicrotasks();

        expect(c.stage, DictationStage.listening);
        expect(c.activeEngine, VoiceEngine.whisper);
        expect(fake.startCount, 1);
        expect(fake.setPreferenceCalls, isEmpty);
        c.dispose();
      });
    });

    test('a failed download falls back to Whisper silently', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(support: LiveSupport.needsDownload);
        final c = _listening(async, fake).controller;

        fake.failDownload();
        async.flushMicrotasks();

        expect(c.stage, DictationStage.listening);
        expect(c.activeEngine, VoiceEngine.whisper);
        expect(c.errorMessage, isNull);
        c.dispose();
      });
    });
  });

  group('switching engine, cancel and dispose', () {
    test('chooseEngine mid-dictation settles Apple and records on Whisper', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final rig = _listening(async, fake);
        final c = rig.controller;
        fake.emitResult('hello');
        async.elapse(const Duration(seconds: 3));

        c.chooseEngine(VoiceEngine.whisper);
        async.flushMicrotasks();

        expect(fake.setPreferenceCalls, [VoiceEngine.whisper]);
        expect(fake.liveStopCount, 1);
        expect(rig.field.draft, isNull);
        expect(rig.field.text, 'hello');
        expect(c.activeEngine, VoiceEngine.whisper);
        expect(fake.startCount, 1);
        expect(c.elapsed, Duration.zero);
        c.dispose();
      });
    });

    test('chooseEngine back to Apple cancels Whisper and goes live', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper);
        final c = _listening(async, fake).controller;
        async.elapse(const Duration(seconds: 3));

        c.chooseEngine(VoiceEngine.apple);
        async.flushMicrotasks();

        expect(fake.setPreferenceCalls, [VoiceEngine.apple]);
        expect(fake.cancelRecordingCount, 1);
        expect(c.activeEngine, VoiceEngine.apple);
        expect(fake.liveStartCount, 1);
        expect(c.elapsed, Duration.zero);
        c.dispose();
      });
    });

    test('dispose while Whisper listens cancels and keeps the text', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper);
        final rig = _listening(async, fake, text: 'typed', caret: 5);

        rig.controller.dispose();
        async.flushMicrotasks();

        expect(fake.cancelRecordingCount, 1);
        expect(rig.field.text, 'typed');
      });
    });

    test('dispose while Apple listens cancels the live session', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = _listening(async, fake).controller;

        c.dispose();
        async.flushMicrotasks();

        expect(fake.liveCancelCount, 1);
      });
    });

    test('dispose while Apple is still starting cancels the live session', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber()..holdLiveStart = true;
        final c = _listening(async, fake).controller;
        expect(fake.liveStartCount, 1);
        expect(c.stage, DictationStage.idle);

        c.dispose();
        fake.completeLiveStart();
        async.flushMicrotasks();

        expect(fake.liveCancelCount, 1);
      });
    });

    test('stop while switching Whisper → Apple does not transcribe', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper)
          ..holdCancelRecording = true;
        final c = _listening(async, fake).controller;

        c.chooseEngine(VoiceEngine.apple);
        async.flushMicrotasks();
        expect(fake.cancelRecordingCount, 1);

        c.toggle();
        fake.interrupt();
        async.flushMicrotasks();
        expect(fake.stopCount, 0);

        fake.completeCancelRecording();
        async.flushMicrotasks();
        expect(fake.stopCount, 0);
        expect(c.activeEngine, VoiceEngine.apple);
        expect(c.stage, DictationStage.listening);
        c.dispose();
      });
    });

    test('interruptions reach the controller that is dictating', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final dictating = _listening(async, fake).controller;
        final other = _Rig(fake).controller;

        fake.interrupt();
        async.flushMicrotasks();

        expect(fake.liveStopCount, 1);
        expect(dictating.stage, DictationStage.idle);
        other.dispose();
        dictating.dispose();
      });
    });

    test(
      'dispose while transcribing cancels; a late transcript is dropped',
      () {
        fakeAsync((async) {
          final fake = FakeVoiceTranscriber(preference: VoiceEngine.whisper)
            ..holdTranscription = true;
          final rig = _listening(async, fake, text: 'typed', caret: 5);
          rig.controller.stop();
          async.flushMicrotasks();

          rig.controller.dispose();
          async.flushMicrotasks();
          expect(fake.cancelTranscriptionCount, 1);

          fake.completeTranscription();
          async.flushMicrotasks();
          expect(rig.field.text, 'typed');
          expect(rig.inserted, isEmpty);
        });
      },
    );

    test('toggle: idle → listening → idle', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = _Rig(fake).controller;
        expect(c.stage, DictationStage.idle);

        c.toggle();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.listening);

        c.toggle();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.idle);
        expect(fake.liveStopCount, 1);
        c.dispose();
      });
    });

    test('toggle while downloading keeps typing', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(support: LiveSupport.needsDownload);
        final c = _listening(async, fake).controller;
        expect(c.stage, DictationStage.downloading);

        c.toggle();
        async.flushMicrotasks();
        expect(c.stage, DictationStage.idle);
        c.dispose();
      });
    });

    test('isActive is exactly listening, downloading and transcribing', () {
      expect(DictationController.activeStages, {
        DictationStage.listening,
        DictationStage.downloading,
        DictationStage.transcribing,
      });
      fakeAsync((async) {
        // idle
        final idle = _Rig(FakeVoiceTranscriber()).controller;
        expect(idle.isActive, isFalse);
        idle.dispose();

        // priming
        final priming = _listening(
          async,
          FakeVoiceTranscriber(status: MicPermission.notDetermined),
        ).controller;
        expect(priming.stage, DictationStage.priming);
        expect(priming.isActive, isFalse);
        priming.dispose();

        // error
        final error = _listening(
          async,
          FakeVoiceTranscriber(status: MicPermission.denied),
        ).controller;
        expect(error.stage, DictationStage.error);
        expect(error.isActive, isFalse);
        error.dispose();

        // downloading
        final downloading = _listening(
          async,
          FakeVoiceTranscriber(support: LiveSupport.needsDownload),
        ).controller;
        expect(downloading.stage, DictationStage.downloading);
        expect(downloading.isActive, isTrue);
        downloading.dispose();

        // listening
        final listening = _listening(async, FakeVoiceTranscriber()).controller;
        expect(listening.isActive, isTrue);
        listening.dispose();
      });
    });
  });
}
