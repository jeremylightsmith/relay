import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';

void main() {
  test('InMemoryBoardPrefs round-trips and clears the slug', () async {
    final prefs = InMemoryBoardPrefs();

    expect(await prefs.readLastBoardSlug(), isNull);

    await prefs.writeLastBoardSlug('marketing-site');
    expect(await prefs.readLastBoardSlug(), 'marketing-site');
    expect(prefs.slug, 'marketing-site');

    await prefs.writeLastBoardSlug('data-pipeline');
    expect(await prefs.readLastBoardSlug(), 'data-pipeline');

    await prefs.clear();
    expect(await prefs.readLastBoardSlug(), isNull);
  });

  test(
    'SecureBoardPrefs degrades to null when the platform is unavailable',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // `flutter test` has no Keychain platform channel: every method must swallow
      // the error — a storage hiccup shows the boards list, never a crash.
      final prefs = SecureBoardPrefs();

      await prefs.writeLastBoardSlug('marketing-site');
      expect(await prefs.readLastBoardSlug(), isNull);
      await prefs.clear();
    },
  );
}
