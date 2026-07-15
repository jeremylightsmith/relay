import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/decisions/answer_stepper.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

FeedQuestion q(
  String prompt, {
  List<String> options = const ['us', 'eu'],
  bool allowText = true,
}) => FeedQuestion(prompt: prompt, options: options, allowText: allowText);

void main() {
  test('canAdvance is false until the current step has a value', () {
    final stepper = AnswerStepper([q('Which region?'), q('Ship it?')]);

    expect(stepper.canAdvance, isFalse);
    stepper.select('eu');
    expect(stepper.canAdvance, isTrue);

    // A fresh step is untouched again — Next re-disables.
    stepper.next();
    expect(stepper.canAdvance, isFalse);
  });

  test('single-select replaces rather than accumulates', () {
    final stepper = AnswerStepper([q('Which region?')]);

    stepper.select('us');
    stepper.select('eu');

    expect(stepper.toAnswers(), [
      {'value': 'eu'},
    ]);
  });

  test('blank text deletes the slot and re-disables Next', () {
    final stepper = AnswerStepper([q('Which region?')]);

    stepper.setText('somewhere else');
    expect(stepper.canAdvance, isTrue);

    stepper.setText('   ');
    expect(stepper.canAdvance, isFalse);
    expect(stepper.toAnswers(), [
      {'value': ''},
    ]);
  });

  test('option-then-text and text-then-option both last-write-win', () {
    final typed = AnswerStepper([q('Which region?')]);
    typed.select('eu');
    typed.setText('somewhere else');
    expect(typed.toAnswers(), [
      {'value': 'somewhere else'},
    ]);

    final picked = AnswerStepper([q('Which region?')]);
    picked.setText('somewhere else');
    picked.select('eu');
    expect(picked.toAnswers(), [
      {'value': 'eu'},
    ]);
  });

  test('customText shows a typed answer but never echoes a picked option', () {
    final stepper = AnswerStepper([q('Which region?')]);
    expect(stepper.customText, '');

    stepper.select('eu');
    expect(stepper.customText, ''); // picking clears the text row

    stepper.setText('somewhere else');
    expect(stepper.customText, 'somewhere else');
  });

  // THE test. answers[] is positional: AllController.compose/2 zips it against
  // latest_questions/1 by index, and answer_value/1 falls through to "" — so a list
  // that reorders, filters or drops an entry mis-attributes silently.
  test('toAnswers emits exactly one entry per question, in question order', () {
    final stepper = AnswerStepper([
      q('Which region?'),
      q('Ship it?'),
      q('Tag it?'),
    ]);

    stepper.select('eu'); // step 0
    stepper.next();
    stepper.next(); // step 1 deliberately skipped
    stepper.select('no'); // step 2

    expect(stepper.toAnswers(), [
      {'value': 'eu'},
      {'value': ''},
      {'value': 'no'},
    ]);
  });

  test('next and back clamp to the question range', () {
    final stepper = AnswerStepper([q('One'), q('Two')]);

    expect(stepper.step, 0);
    stepper.back();
    expect(stepper.step, 0);

    stepper.next();
    stepper.next();
    expect(stepper.step, 1);
    expect(stepper.isLast, isTrue);
  });

  test('a single-question round is immediately on its last step', () {
    expect(AnswerStepper([q('Only one')]).isLast, isTrue);
  });
}
