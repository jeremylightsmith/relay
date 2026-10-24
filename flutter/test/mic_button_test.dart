import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/voice/dictation_text_controller.dart';
import 'package:relay_mobile/features/voice/mic_button.dart';

import 'support/fake_voice_transcriber.dart';

final _mic = find.byType(MicButton);
final _field = find.byType(TextField);
final _toolbar = find.byKey(const Key('dictation_toolbar'));
final _stop = find.byKey(const Key('dictation_stop'));

/// The 390×844 test phone with a 300px keyboard up.
const _screenHeight = 844.0;
const _keyboard = 300.0;

class _Rig {
  _Rig(String initial)
    : controller = DictationTextController(text: initial),
      focusNode = FocusNode();

  final DictationTextController controller;
  final FocusNode focusNode;
}

/// Pumps a [MicButton] beside a [TextField] that shares its controller and
/// focus node — the shape both hosts use.
Future<_Rig> _pump(
  WidgetTester tester,
  FakeVoiceTranscriber fake, {
  String initial = '',
  ValueChanged<String>? onInserted,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, _screenHeight);
  tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
  addTearDown(tester.view.reset);

  final rig = _Rig(initial);
  addTearDown(() {
    rig.focusNode.dispose();
    rig.controller.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: Scaffold(
        body: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: rig.controller,
                    focusNode: rig.focusNode,
                    maxLines: null,
                  ),
                ),
                MicButton(
                  controller: rig.controller,
                  focusNode: rig.focusNode,
                  voice: fake.engines,
                  onInserted: onInserted,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return rig;
}

/// Taps the mic and lets the fake engines' async answers settle.
Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(_mic);
  await tester.pump();
  await tester.pump();
}

BoxDecoration _circle(WidgetTester tester) =>
    tester.widget<Container>(find.byKey(const Key('mic_circle'))).decoration!
        as BoxDecoration;

void main() {
  testWidgets('9 · a tap focuses the field and pins the toolbar on the '
      'keyboard; the mic turns red', (tester) async {
    final fake = FakeVoiceTranscriber();
    final rig = await _pump(tester, fake);
    expect(rig.focusNode.hasFocus, isFalse);

    await _tapMic(tester);

    expect(rig.focusNode.hasFocus, isTrue);
    expect(_toolbar, findsOneWidget);
    expect(tester.getRect(_toolbar).bottom, _screenHeight - _keyboard);
    final circle = _circle(tester);
    expect(circle.color, RelayTheme.relayMicActiveFill);
    expect(circle.border, Border.all(color: RelayTheme.relayMicActiveBorder));
    final glyph = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const Key('mic_circle')),
            matching: find.byType(Container),
          )
          .last,
    );
    expect(
      (glyph.decoration! as BoxDecoration).color,
      RelayTheme.relayMicActiveGlyph,
    );
  });

  testWidgets('10 · live words stream into the field as a faded draft', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    final rig = await _pump(tester, fake);
    await _tapMic(tester);

    fake.emitResult('yes publish');
    await tester.pump();

    expect(tester.widget<TextField>(_field).controller!.text, 'yes publish');
    expect(rig.controller.text, 'yes publish');
    // A TextField paints through RenderEditable (no RichText widget): its
    // `text` is the span the field actually renders.
    final painted = tester
        .state<EditableTextState>(
          find.descendant(of: _field, matching: find.byType(EditableText)),
        )
        .renderEditable
        .text!;
    final draftSpans = <TextSpan>[];
    painted.visitChildren((span) {
      if (span is TextSpan &&
          span.style?.color == RelayTheme.relayDictationDraft) {
        draftSpans.add(span);
      }
      return true;
    });
    expect(draftSpans.map((span) => span.text), ['yes publish']);
  });

  testWidgets('11 · stop restores a plain, still-focused field', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    final rig = await _pump(tester, fake);
    await _tapMic(tester);
    fake.emitResult('yes publish');
    await tester.pump();

    await tester.tap(_stop);
    await tester.pump();
    await tester.pump();

    expect(_toolbar, findsNothing);
    expect(rig.focusNode.hasFocus, isTrue, reason: 'the keyboard stays');
    expect(_circle(tester).color, RelayTheme.relayMicFill);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(rig.controller.draft, isNull);
    expect(rig.controller.text, 'yes publish');
  });

  testWidgets('12 · tapping the mic again stops too', (tester) async {
    final fake = FakeVoiceTranscriber();
    await _pump(tester, fake);
    await _tapMic(tester);
    expect(_toolbar, findsOneWidget);

    await _tapMic(tester);

    expect(_toolbar, findsNothing);
    expect(fake.liveStopCount, 1);
  });

  testWidgets('13 · onInserted fires with the dictated text', (tester) async {
    final fake = FakeVoiceTranscriber();
    final inserted = <String>[];
    await _pump(tester, fake, onInserted: inserted.add);
    await _tapMic(tester);

    fake.emitResult('ship it', isFinal: true);
    await tester.pump();

    expect(inserted, ['ship it']);
  });

  testWidgets('14 · leaving mid-dictation cancels and keeps the text', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    final rig = await _pump(tester, fake, initial: 'typed ');
    await _tapMic(tester);

    await tester.pumpWidget(const SizedBox());

    expect(fake.liveCancelCount, 1);
    expect(rig.controller.text, 'typed ');
  });

  testWidgets('15 · the idle mic wears the violet trio and announces as '
      'Dictate', (tester) async {
    final fake = FakeVoiceTranscriber();
    await _pump(tester, fake);

    final circle = tester.widget<Container>(
      find.byKey(const Key('mic_circle')),
    );
    final deco = circle.decoration! as BoxDecoration;
    expect(deco.color, RelayTheme.relayMicFill);
    expect(deco.border, Border.all(color: RelayTheme.relayMicBorder));
    expect(deco.shape, BoxShape.circle);
    expect(circle.constraints, BoxConstraints.tight(const Size(30, 30)));
    final glyph = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(const Key('mic_circle')),
            matching: find.byType(Container),
          )
          .last,
    );
    expect(
      (glyph.decoration! as BoxDecoration).color,
      RelayTheme.relayMicGlyph,
    );

    expect(
      find.bySemanticsLabel('Dictate'),
      findsOneWidget,
      reason: 'live control, announced — unlike the old ExcludeSemantics ghost',
    );
  });
}
