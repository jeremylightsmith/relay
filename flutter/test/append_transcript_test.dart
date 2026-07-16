import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/voice/append_transcript.dart';

void main() {
  group('appendTranscript (D7)', () {
    test('returns the transcript unchanged when the field is empty', () {
      expect(appendTranscript('', 'second part'), 'second part');
      expect(appendTranscript('   ', 'second part'), 'second part');
    });

    test('joins with a single space — criterion 5', () {
      expect(
        appendTranscript('first part', 'second part'),
        'first part second part',
      );
    });

    test('never doubles whitespace after a trailing space or newline', () {
      expect(appendTranscript('first ', 'second'), 'first second');
      expect(appendTranscript('first\n', 'second'), 'first\nsecond');
    });

    test('an empty transcript leaves the field untouched', () {
      expect(appendTranscript('typed already', '  '), 'typed already');
    });

    test('trims the transcript itself', () {
      expect(appendTranscript('a', '  b  '), 'a b');
    });
  });
}
