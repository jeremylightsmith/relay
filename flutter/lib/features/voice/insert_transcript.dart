import 'package:flutter/services.dart';

/// The result of [insertTranscript]: the new field text, and the [range] the
/// inserted chunk occupies in it — **including** any padding space the call
/// added, so removing [range] undoes the insertion exactly.
class TranscriptInsertion {
  const TranscriptInsertion({required this.text, required this.range});

  final String text;
  final TextRange range;
}

final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isSpace(String char) => char == ' ' || char == '\n';

/// Inserts [transcript] into [existing] at [offset] (the cursor) — RE467's
/// generalization of RLY-99's end-of-field append. Trims the transcript,
/// clamps [offset], pads with one space on either side only where
/// the neighbouring text needs it, and never doubles whitespace. An empty or
/// whitespace-only field yields the bare transcript.
TranscriptInsertion insertTranscript(
  String existing,
  int offset,
  String transcript,
) {
  final at = offset.clamp(0, existing.length);
  final words = transcript.trim();
  if (words.isEmpty) {
    return TranscriptInsertion(text: existing, range: TextRange.collapsed(at));
  }
  if (existing.trim().isEmpty) {
    return TranscriptInsertion(
      text: words,
      range: TextRange(start: 0, end: words.length),
    );
  }

  final lead = at > 0 && !_isSpace(existing[at - 1]) ? ' ' : '';
  final trail = at < existing.length && _wordChar.hasMatch(existing[at])
      ? ' '
      : '';
  final chunk = '$lead$words$trail';
  return TranscriptInsertion(
    text: existing.replaceRange(at, at, chunk),
    range: TextRange(start: at, end: at + chunk.length),
  );
}
