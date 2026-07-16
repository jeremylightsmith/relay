/// Initials for an avatar fallback — the shared rule (RLY-90 [E4]), mirrored
/// by the web's `avatar_initials/2` so the same person reads the same on both
/// clients: a name yields the first letters of its first two words; with no
/// name, the email's LOCAL PART split on `.`/`_`/`-`/whitespace (so
/// dana@acme.co → D, never DA — the domain is not a name); both blank → '?'.
String initialsFor(String? name, String? email) {
  final trimmedName = name?.trim() ?? '';
  if (trimmedName.isNotEmpty) {
    return _firstLetters(trimmedName.split(RegExp(r'\s+')));
  }
  final trimmedEmail = email?.trim() ?? '';
  if (trimmedEmail.isNotEmpty) {
    final localPart = trimmedEmail.split('@').first;
    return _firstLetters(localPart.split(RegExp(r'[._\s-]+')));
  }
  return '?';
}

String _firstLetters(List<String> words) {
  final letters = words
      .where((word) => word.isNotEmpty)
      .take(2)
      .map((word) => word[0].toUpperCase())
      .join();
  return letters.isEmpty ? '?' : letters;
}
