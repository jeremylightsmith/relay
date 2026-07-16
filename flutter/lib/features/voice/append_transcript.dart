/// D7: additive is recoverable; replace silently destroys typing. Joins with a
/// single space (or nothing after a trailing space/newline), never doubles
/// whitespace, and returns the transcript alone when the field is empty.
String appendTranscript(String existing, String transcript) {
  final addition = transcript.trim();
  if (addition.isEmpty) return existing;
  if (existing.trim().isEmpty) return addition;

  final endsOpen = existing.endsWith(' ') || existing.endsWith('\n');
  return endsOpen ? '$existing$addition' : '$existing $addition';
}
