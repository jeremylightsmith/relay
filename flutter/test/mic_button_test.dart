import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/voice/mic_button.dart';

import 'support/fake_voice_transcriber.dart';

final _mic = find.byType(MicButton);
final _stop = find.byKey(const Key('voice_stop'));
final _use = find.byKey(const Key('voice_use'));

Future<TextEditingController> _pump(
  WidgetTester tester,
  FakeVoiceTranscriber fake, {
  String initial = '',
  ValueChanged<String>? onInserted,
}) async {
  final controller = TextEditingController(text: initial);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: Scaffold(
        body: MicButton(
          controller: controller,
          transcriber: fake,
          onInserted: onInserted,
        ),
      ),
    ),
  );
  return controller;
}

Future<void> _dictate(WidgetTester tester) async {
  await tester.tap(_mic);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(_stop);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(_use);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('dictating appends to existing text (criterion 5)', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber(transcript: 'second part');
    String? inserted;
    final controller = await _pump(
      tester,
      fake,
      initial: 'first part',
      onInserted: (t) => inserted = t,
    );

    await _dictate(tester);

    expect(controller.text, 'first part second part');
    expect(
      inserted,
      'first part second part',
      reason: 'hosts recompute canSend through onInserted',
    );
  });

  testWidgets('an empty field takes the transcript alone', (tester) async {
    final fake = FakeVoiceTranscriber(transcript: 'use the EU region');
    final controller = await _pump(tester, fake);

    await _dictate(tester);

    expect(controller.text, 'use the EU region');
  });

  testWidgets('cancel leaves pre-existing text untouched (criterion 4)', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    final controller = await _pump(tester, fake, initial: 'typed already');

    await tester.tap(_mic);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(_stop);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('voice_review_cancel')));
    await tester.pumpAndSettle();

    expect(controller.text, 'typed already');
  });

  testWidgets('the mic wears the live violet trio and announces as Dictate', (
    tester,
  ) async {
    final fake = FakeVoiceTranscriber();
    await _pump(tester, fake);

    final circle = tester.widget<Container>(
      find.descendant(of: _mic, matching: find.byType(Container)).first,
    );
    final deco = circle.decoration! as BoxDecoration;
    expect(deco.color, RelayTheme.relayMicFill);
    expect(deco.border, Border.all(color: RelayTheme.relayMicBorder));
    expect(deco.shape, BoxShape.circle);
    expect(circle.constraints, BoxConstraints.tight(const Size(30, 30)));

    expect(
      find.bySemanticsLabel('Dictate'),
      findsOneWidget,
      reason: 'live control, announced — unlike the old ExcludeSemantics ghost',
    );
  });
}
