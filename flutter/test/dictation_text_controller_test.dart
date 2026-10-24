import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/voice/dictation_text_controller.dart';

const _base = TextStyle(fontSize: 15, color: Colors.black);

/// Builds [controller]'s span inside a test MaterialApp, as a TextField would.
Future<TextSpan> _build(
  WidgetTester tester,
  DictationTextController controller,
) async {
  late TextSpan span;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          span = controller.buildTextSpan(
            context: context,
            style: _base,
            withComposing: false,
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return span;
}

List<TextSpan> _leaves(TextSpan span) {
  final leaves = <TextSpan>[];
  span.visitChildren((child) {
    if (child is TextSpan && (child.text ?? '').isNotEmpty) leaves.add(child);
    return true;
  });
  return leaves;
}

void main() {
  testWidgets('paints the draft range faded violet, the rest in the base '
      'style', (tester) async {
    final controller = DictationTextController(
      text: 'Yes, publish it goes to spec',
    );
    controller.draft = const TextRange(start: 13, end: 28);

    final span = await _build(tester, controller);
    final leaves = _leaves(span);

    expect(leaves.map((s) => s.text), ['Yes, publish ', 'it goes to spec']);
    expect(leaves[0].style?.color, Colors.black);
    expect(leaves[1].style?.color, RelayTheme.relayDictationDraft);
    expect(leaves[1].style?.decoration, TextDecoration.none);
    expect(leaves[1].style?.fontSize, 15);
    expect(span.toPlainText(), controller.text);
    controller.dispose();
  });

  testWidgets('an out-of-range draft falls back to one plain span', (
    tester,
  ) async {
    final controller = DictationTextController(text: 'short');
    controller.draft = const TextRange(start: 5, end: 99);

    final span = await _build(tester, controller);
    final leaves = _leaves(span);

    expect(leaves.map((s) => s.text), ['short']);
    expect(
      leaves.single.style?.color ?? span.style?.color,
      isNot(RelayTheme.relayDictationDraft),
    );
    expect(span.toPlainText(), 'short');
    controller.dispose();
  });

  test('setting draft notifies listeners once', () {
    final controller = DictationTextController(text: 'hello');
    var notified = 0;
    controller.addListener(() => notified++);

    controller.draft = const TextRange(start: 0, end: 5);

    expect(notified, 1);
    expect(controller.draft, const TextRange(start: 0, end: 5));
    expect(controller.text, 'hello');
    controller.dispose();
  });
}
