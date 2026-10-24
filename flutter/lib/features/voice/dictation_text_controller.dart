import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A [TextEditingController] that paints the live dictation [draft] — Apple's
/// volatile words — faded violet. Only the rendering changes: [text] and
/// [value] hold plain characters, so what ✓ sends is plain text.
class DictationTextController extends TextEditingController {
  DictationTextController({super.text});

  TextRange? _draft;

  /// The range of [text] still volatile, or null when every word is ink.
  TextRange? get draft => _draft;

  set draft(TextRange? range) {
    if (range == _draft) return;
    _draft = range;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final range = _draft;
    if (range == null ||
        !range.isValid ||
        range.isCollapsed ||
        range.end > text.length) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: range.textBefore(text), style: style),
        TextSpan(
          text: range.textInside(text),
          style: base.copyWith(
            color: RelayTheme.relayDictationDraft,
            decoration: TextDecoration.none,
          ),
        ),
        TextSpan(text: range.textAfter(text), style: style),
      ],
    );
  }
}
