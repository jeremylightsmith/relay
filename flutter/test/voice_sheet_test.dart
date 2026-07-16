import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/voice/voice_sheet.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

import 'support/fake_voice_transcriber.dart';

final _sheet = find.byKey(const Key('voice_sheet'));
final _stop = find.byKey(const Key('voice_stop'));
final _use = find.byKey(const Key('voice_use'));
final _transcript = find.byKey(const Key('voice_transcript'));

/// A host with a button that opens the sheet and records the returned value.
class _Host extends StatelessWidget {
  const _Host({required this.fake, required this.onResult});

  final FakeVoiceTranscriber fake;
  final ValueChanged<String?> onResult;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: RelayTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open_sheet'),
              onPressed: () async =>
                  onResult(await showVoiceSheet(context, transcriber: fake)),
              child: const Text('mic'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  FakeVoiceTranscriber fake,
  void Function(String?) onResult,
) async {
  await tester.pumpWidget(_Host(fake: fake, onResult: onResult));
  await tester.tap(find.byKey(const Key('open_sheet')));
  // Sheet slide-in + controller.start(); bounded pumps — the recording pulse
  // repeats forever, so pumpAndSettle would hang.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _stopAndReview(WidgetTester tester) async {
  await tester.tap(_stop);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('granted permission goes straight to recording with a timer', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    await _open(tester, fake, (_) {});

    expect(find.byKey(const Key('voice_recording')), findsOneWidget);
    expect(find.text('00:00'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.text('00:03'), findsOneWidget);

    // D8: no cap — two minutes in, still recording, still counting.
    await tester.pump(const Duration(minutes: 2));
    expect(find.byKey(const Key('voice_recording')), findsOneWidget);
    expect(find.text('02:03'), findsOneWidget);

    await _stopAndReview(tester); // leave no live timer behind the test
    await tester.tap(find.byKey(const Key('voice_review_cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('the review sheet matches the Voice · Whisper artboard', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(
      transcript: 'Yes, publish, but fix the second one.',
    );
    await _open(tester, fake, (_) {});
    await _stopAndReview(tester);

    // Container: white, 22px top radius, padding 20/18/22.
    final sheet = tester.widget<Container>(_sheet);
    final deco = sheet.decoration! as BoxDecoration;
    expect(deco.color, Colors.white);
    expect(
      deco.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(22)),
    );
    expect(sheet.padding, const EdgeInsets.fromLTRB(18, 20, 18, 22));

    // Header: 34px violet circle — found by its pinned size, not tree index.
    final badge = tester.widget<Container>(
      find.descendant(
        of: _sheet,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints == BoxConstraints.tight(const Size(34, 34)),
        ),
      ),
    );
    expect((badge.decoration! as BoxDecoration).color, RelayTheme.relayAI);
    expect((badge.decoration! as BoxDecoration).shape, BoxShape.circle);

    // "You said" — 13px w600 near-black.
    final youSaid = tester.widget<Text>(
      find.byKey(const Key('voice_you_said')),
    );
    expect(youSaid.style!.fontSize, 13);
    expect(youSaid.style!.fontWeight, FontWeight.w600);
    expect(youSaid.style!.color, const Color(0xFF1E252E));

    // Provenance — 9.5px monospace in the new darker-green token.
    final prov = tester.widget<Text>(find.byKey(const Key('voice_provenance')));
    expect(prov.data, 'TRANSCRIBED · WHISPER · TAP TO EDIT');
    expect(prov.style!.fontSize, 9.5);
    expect(prov.style!.fontFamily, 'monospace');
    expect(prov.style!.color, RelayTheme.relayVoiceTranscribed);

    // Transcript box: 1.5px violet-tinted border, 12 radius, 12 padding,
    // 13.5px text, violet caret, editable.
    final box = tester.widget<Container>(
      find.byKey(const Key('voice_transcript_box')),
    );
    final boxDeco = box.decoration! as BoxDecoration;
    expect(
      boxDeco.border,
      Border.all(color: const Color(0xFFD1CEE4), width: 1.5),
    );
    expect(boxDeco.borderRadius, BorderRadius.circular(12));
    expect(box.padding, const EdgeInsets.all(12));
    final field = tester.widget<TextField>(_transcript);
    expect(field.style!.fontSize, 13.5);
    expect(field.cursorColor, RelayTheme.relayAI);
    expect(field.controller!.text, 'Yes, publish, but fix the second one.');

    // Footer: Use this is BLUE (the human acts), flex 10:13 ≡ 1:1.3.
    final useBtn = tester.widget<FilledButton>(_use);
    expect(useBtn.style!.backgroundColor!.resolve({}), RelayTheme.relayHuman);
    final flexes = [
      tester.widget<Expanded>(
        find.ancestor(
          of: find.byKey(const Key('voice_review_cancel')),
          matching: find.byType(Expanded),
        ),
      ),
      tester.widget<Expanded>(
        find.ancestor(of: _use, matching: find.byType(Expanded)),
      ),
    ].map((e) => e.flex);
    expect(flexes, [10, 13]);

    await tester.tap(find.byKey(const Key('voice_review_cancel')));
    await tester.pumpAndSettle();
  });

  testWidgets('"Use this" returns the hand-edited transcript (criterion 3)', (
    tester,
  ) async {
    String? result = 'sentinel';
    final fake = FakeVoiceTranscriber(transcript: 'original words');
    await _open(tester, fake, (r) => result = r);
    await _stopAndReview(tester);

    await tester.enterText(_transcript, 'edited by hand');
    await tester.tap(_use);
    await tester.pumpAndSettle();

    expect(result, 'edited by hand');
    expect(_sheet, findsNothing);
  });

  testWidgets('Cancel from review returns null (criterion 4)', (tester) async {
    String? result = 'sentinel';
    final fake = FakeVoiceTranscriber();
    await _open(tester, fake, (r) => result = r);
    await _stopAndReview(tester);

    await tester.tap(find.byKey(const Key('voice_review_cancel')));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(_sheet, findsNothing);
  });

  testWidgets(
    'notDetermined shows priming; denial closes quietly (criterion 7)',
    (tester) async {
      String? result = 'sentinel';
      final fake = FakeVoiceTranscriber(
        status: MicPermission.notDetermined,
        statusAfterRequest: MicPermission.denied,
      );
      await _open(tester, fake, (r) => result = r);

      expect(find.byKey(const Key('voice_priming')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice_allow_mic')));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(_sheet, findsNothing);
      expect(find.byType(AlertDialog), findsNothing, reason: 'no nag');
    },
  );

  testWidgets('previously denied offers Open Settings and Type instead', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(status: MicPermission.denied);
    await _open(tester, fake, (_) {});

    expect(find.text('Microphone access is off for Relay.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice_open_settings')));
    await tester.pump();
    expect(fake.openSettingsCount, 1);

    await tester.tap(find.byKey(const Key('voice_type_instead')));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
  });

  testWidgets('transcribing is cancellable (criterion 11)', (tester) async {
    String? result = 'sentinel';
    final fake = FakeVoiceTranscriber()..holdTranscription = true;
    await _open(tester, fake, (r) => result = r);

    await tester.tap(_stop);
    await tester.pump();
    expect(find.byKey(const Key('voice_transcribing')), findsOneWidget);

    await tester.tap(find.byKey(const Key('voice_cancel')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(fake.cancelTranscriptionCount, 1);

    fake.completeTranscription(); // late result must be discarded quietly
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
  });

  testWidgets(
    'an empty transcription shows "Didn\'t catch that." + Try again',
    (tester) async {
      final fake = FakeVoiceTranscriber(transcript: '   ');
      await _open(tester, fake, (_) {});
      await _stopAndReview(tester);

      expect(find.text("Didn't catch that."), findsOneWidget);

      fake.transcript = 'second try';
      await tester.tap(find.byKey(const Key('voice_try_again')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('voice_recording')), findsOneWidget);

      await _stopAndReview(tester);
      expect(
        tester.widget<TextField>(_transcript).controller!.text,
        'second try',
      );

      await tester.tap(find.byKey(const Key('voice_review_cancel')));
      await tester.pumpAndSettle();
    },
  );
}
