import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/voice_controller.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

import 'support/fake_voice_transcriber.dart';

void main() {
  group('permission gating', () {
    test('granted goes straight to recording', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.recording);
        expect(fake.startCount, 1);
        c.dispose();
      });
    });

    test('notDetermined primes first; Allow then records', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(status: MicPermission.notDetermined);
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.priming);

        c.allowMic();
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.recording);
        expect(fake.requestCount, 1);
        c.dispose();
      });
    });

    test('denial at the OS prompt dismisses — no nag (criterion 7)', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          status: MicPermission.notDetermined,
          statusAfterRequest: MicPermission.denied,
        );
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.allowMic();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.dismissed);
        expect(fake.startCount, 0);
        c.dispose();
      });
    });

    test('previously denied offers Open Settings, not Try again', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(status: MicPermission.denied);
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.error);
        expect(c.errorMessage, 'Microphone access is off for Relay.');
        expect(c.showOpenSettings, isTrue);
        expect(c.showTryAgain, isFalse);

        c.openSettings();
        async.flushMicrotasks();
        expect(fake.openSettingsCount, 1);
        c.dispose();
      });
    });
  });

  group('recording (D8: no cap)', () {
    test('the elapsed timer counts up, uncapped', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 3));
        expect(c.elapsed, const Duration(seconds: 3));

        // Past the 60s a cap would have imposed — still recording.
        async.elapse(const Duration(minutes: 2));
        expect(c.stage, VoiceStage.recording);
        expect(c.elapsed, const Duration(minutes: 2, seconds: 3));
        c.dispose();
      });
    });

    test('a failing recorder lands on error with Try again', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          startError: const VoiceError(VoiceErrorKind.recordingFailed),
        );
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.error);
        expect(c.errorMessage, "Didn't catch that.");
        expect(c.showTryAgain, isTrue);
        c.dispose();
      });
    });
  });

  group('stop → transcribe → review', () {
    test('a transcript lands in review, trimmed', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(transcript: '  use the EU region  ');
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.stopAndReview();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.review);
        expect(c.transcript, 'use the EU region');
        c.dispose();
      });
    });

    test('an empty transcript never opens review — "Didn\'t catch that."', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(transcript: '   ');
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.stopAndReview();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.error);
        expect(c.errorMessage, "Didn't catch that.");
        expect(c.showTryAgain, isTrue);
        c.dispose();
      });
    });

    test('a model failure reads as plain cause, never a raw error', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(
          stopError: const VoiceError(VoiceErrorKind.modelUnavailable),
        );
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.stopAndReview();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.error);
        expect(c.errorMessage, "Voice isn't available right now.");
        c.dispose();
      });
    });

    test('Try again from error records afresh', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber(transcript: '');
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.stopAndReview();
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.error);

        fake.transcript = 'second try';
        c.tryAgain();
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.recording);
        expect(c.elapsed, Duration.zero);
        c.dispose();
      });
    });
  });

  group('cancellation at every stage', () {
    test('cancel while recording discards the clip', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber();
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.cancel();
        async.flushMicrotasks();

        expect(c.stage, VoiceStage.dismissed);
        expect(fake.cancelRecordingCount, 1);
        c.dispose();
      });
    });

    test('cancel while transcribing stops the wait; a late result is discarded '
        '(criterion 11)', () {
      fakeAsync((async) {
        final fake = FakeVoiceTranscriber()..holdTranscription = true;
        final c = VoiceController(fake);
        c.start();
        async.flushMicrotasks();
        c.stopAndReview();
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.transcribing);

        c.cancel();
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.dismissed);
        expect(fake.cancelTranscriptionCount, 1);

        fake.completeTranscription('too late');
        async.flushMicrotasks();
        expect(c.stage, VoiceStage.dismissed);
        expect(c.transcript, isEmpty);
        c.dispose();
      });
    });
  });

  test('an interruption mid-recording transcribes the partial clip', () {
    fakeAsync((async) {
      final fake = FakeVoiceTranscriber(transcript: 'partial thought');
      final c = VoiceController(fake);
      c.start();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));

      fake.interrupt();
      async.flushMicrotasks();

      expect(c.stage, VoiceStage.review);
      expect(c.transcript, 'partial thought');
      c.dispose();
    });
  });
}
