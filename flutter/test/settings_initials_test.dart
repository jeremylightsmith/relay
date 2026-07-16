import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/settings/initials.dart';

void main() {
  test('two-word names take both first letters', () {
    expect(initialsFor('Dana Kim', 'dana@acme.co'), 'DK');
  });

  test('one-word names take a single letter', () {
    expect(initialsFor('Dana', null), 'D');
  });

  test('extra words beyond two are ignored', () {
    expect(initialsFor('Ada King Lovelace', null), 'AK');
  });

  test('a blank name falls back to the email local part', () {
    expect(initialsFor('', 'dana@acme.co'), 'D');
    expect(initialsFor(null, 'dana.kim@acme.co'), 'DK');
  });

  test('the domain never leaks into initials', () {
    // the old web top-bar bug rendered DA for dana@acme.co — the A was "acme"
    expect(initialsFor(null, 'dana@acme.co'), isNot('DA'));
  });

  test('local parts split on dot, underscore, dash, and whitespace', () {
    expect(initialsFor(null, 'dana_kim@acme.co'), 'DK');
    expect(initialsFor(null, 'dana-kim@acme.co'), 'DK');
  });

  test('both blank yields ?', () {
    expect(initialsFor(null, null), '?');
    expect(initialsFor('   ', ''), '?');
  });

  test('lowercase input is upcased and stray whitespace tolerated', () {
    expect(initialsFor('  dana   kim  ', null), 'DK');
  });
}
