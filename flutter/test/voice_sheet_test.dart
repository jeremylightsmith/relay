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
final _reviewCancel = find.byKey(const Key('voice_review_cancel'));
final _provenance = find.byKey(const Key('voice_provenance'));
final _header = find.byKey(const Key('sheet_header'));
final _body = find.byKey(const Key('sheet_body'));

/// 7,999 chars — long enough to overflow any phone sheet.
final _longTranscript = List.filled(800, 'dictation').join(' ');

FakeVoiceTranscriber _longFake() =>
    FakeVoiceTranscriber(transcript: _longTranscript);

/// A 390×844 phone (status bar 47, home indicator 34) with a 300px keyboard
/// up: the visible area is y ∈ [47, 544].
void _phoneWithKeyboard(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  addTearDown(tester.view.reset);
}

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

  testWidgets('the review sheet matches card mockup B (header action)', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(
      transcript: 'Yes, publish, but fix the second one.',
    );
    await _open(tester, fake, (_) {});
    await _stopAndReview(tester);

    // Container: white, 22px top radius; HeaderedSheet supplies the paddings.
    final sheet = tester.widget<Container>(_sheet);
    final deco = sheet.decoration! as BoxDecoration;
    expect(deco.color, Colors.white);
    expect(
      deco.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(22)),
    );
    expect(sheet.padding, EdgeInsets.zero);

    // Header: 24px violet circle — found by its pinned size, not tree index.
    final badge = tester.widget<Container>(
      find.descendant(
        of: _header,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints == BoxConstraints.tight(const Size(24, 24)),
        ),
      ),
    );
    expect((badge.decoration! as BoxDecoration).color, RelayTheme.relayAI);
    expect((badge.decoration! as BoxDecoration).shape, BoxShape.circle);

    // "You said" — in the header, 14px w600 near-black.
    final youSaidFinder = find.descendant(
      of: _header,
      matching: find.byKey(const Key('voice_you_said')),
    );
    final youSaid = tester.widget<Text>(youSaidFinder);
    expect(youSaid.style!.fontSize, 14);
    expect(youSaid.style!.fontWeight, FontWeight.w600);
    expect(youSaid.style!.color, const Color(0xFF1E252E));

    // Provenance — in the scrolling body, not the header; style unchanged.
    expect(find.descendant(of: _body, matching: _provenance), findsOneWidget);
    expect(find.descendant(of: _header, matching: _provenance), findsNothing);
    final prov = tester.widget<Text>(_provenance);
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

    // Header action: Use this is BLUE (the human acts).
    final useBtn = tester.widget<FilledButton>(
      find.descendant(of: _use, matching: find.byType(FilledButton)),
    );
    final bg = useBtn.style!.backgroundColor!.resolve({});
    expect(bg, RelayTheme.relayHuman);

    // Cancel left | "You said" centre | Use this right.
    final cancelX = tester.getCenter(_reviewCancel).dx;
    final youSaidX = tester.getCenter(youSaidFinder).dx;
    final useX = tester.getCenter(_use).dx;
    expect(cancelX, lessThan(youSaidX));
    expect(youSaidX, lessThan(useX));

    // The flex 10:13 bottom row is gone.
    expect(
      find.ancestor(of: _use, matching: find.byType(Expanded)),
      findsNothing,
    );
    expect(
      find.ancestor(of: _reviewCancel, matching: find.byType(Expanded)),
      findsNothing,
    );

    await tester.tap(_reviewCancel);
    await tester.pumpAndSettle();
  });

  testWidgets('the recording stage keeps its padding and full-width Stop', (
    tester,
  ) async {
    await _open(tester, FakeVoiceTranscriber(), (_) {});

    expect(
      tester.widget<Container>(_sheet).padding,
      const EdgeInsets.fromLTRB(18, 20, 18, 22),
    );
    expect(tester.widget(_stop), isA<FilledButton>());
    final sheetRect = tester.getRect(_sheet);
    expect(tester.getSize(_stop).width, sheetRect.width - 36);

    await _stopAndReview(tester);
    await tester.tap(_reviewCancel);
    await tester.pumpAndSettle();
  });

  testWidgets('a long dictation can still be accepted with the keyboard up', (
    tester,
  ) async {
    _phoneWithKeyboard(tester);
    String? result = 'sentinel';
    await _open(tester, _longFake(), (r) => result = r);
    await _stopAndReview(tester);

    expect(_use.hitTestable(), findsOneWidget);
    final useRect = tester.getRect(_use);
    expect(useRect.top, greaterThanOrEqualTo(47));
    expect(useRect.bottom, lessThanOrEqualTo(544));

    await tester.tap(_use);
    await tester.pumpAndSettle();

    expect(result, _longTranscript);
    expect(result!.length, 7999);
    expect(_sheet, findsNothing);
  });

  testWidgets('the body scrolls under a fixed header', (tester) async {
    _phoneWithKeyboard(tester);
    await _open(tester, _longFake(), (_) {});
    await _stopAndReview(tester);

    final provBefore = tester.getRect(_provenance);
    final useBefore = tester.getRect(_use);

    await tester.drag(_body, const Offset(0, -2000));
    await tester.pumpAndSettle();

    expect(tester.getRect(_provenance).top, lessThan(provBefore.top));
    expect(tester.getRect(_use), useBefore);

    await tester.tap(_reviewCancel);
    await tester.pumpAndSettle();
  });

  testWidgets('a long hand-edited transcript returns in full', (tester) async {
    _phoneWithKeyboard(tester);
    String? result = 'sentinel';
    await _open(tester, _longFake(), (r) => result = r);
    await _stopAndReview(tester);

    final edited = 'edited by hand ' * 300;
    await tester.enterText(_transcript, edited);
    await tester.tap(_use);
    await tester.pumpAndSettle();

    expect(result, edited.trim());
  });

  testWidgets('a long review sheet stops below the top safe area', (
    tester,
  ) async {
    _phoneWithKeyboard(tester);
    await _open(tester, _longFake(), (_) {});
    await _stopAndReview(tester);

    expect(tester.getRect(_sheet).top, greaterThanOrEqualTo(47));

    await tester.tap(_reviewCancel);
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
