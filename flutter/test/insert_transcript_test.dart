import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/insert_transcript.dart';

void main() {
  group('insertTranscript (RE467)', () {
    // (existing, offset, transcript) → (text, range)
    final cases = <(String, int, String, String, TextRange)>[
      ('', 0, '  hello ', 'hello', const TextRange(start: 0, end: 5)),
      (
        'Fix the bug',
        11,
        'today',
        'Fix the bug today',
        const TextRange(start: 11, end: 17),
      ),
      (
        'Fix the bug ',
        12,
        'today',
        'Fix the bug today',
        const TextRange(start: 12, end: 17),
      ),
      ('Fix bug', 4, 'the', 'Fix the bug', const TextRange(start: 4, end: 8)),
      ('stage.', 5, 'now', 'stage now.', const TextRange(start: 5, end: 9)),
      ('line\n', 5, 'next', 'line\nnext', const TextRange(start: 5, end: 9)),
      ('abc', 99, 'x', 'abc x', const TextRange(start: 3, end: 5)),
      ('keep', 2, '   ', 'keep', const TextRange.collapsed(2)),
    ];

    for (final (existing, offset, transcript, text, range) in cases) {
      test('(${_q(existing)}, $offset, ${_q(transcript)}) → ${_q(text)} '
          '${range.start}–${range.end}', () {
        final result = insertTranscript(existing, offset, transcript);
        expect(result.text, text);
        expect(result.range, range);
      });
    }

    test('a whitespace-only field yields the bare transcript', () {
      final result = insertTranscript('   ', 3, 'hi');
      expect(result.text, 'hi');
      expect(result.range, const TextRange(start: 0, end: 2));
    });
  });
}

String _q(String s) => "'${s.replaceAll('\n', r'\n')}'";
