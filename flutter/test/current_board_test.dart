import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/current_board.dart';

ProviderContainer containerWith(BoardPrefs prefs) {
  final c = ProviderContainer(
    overrides: [boardPrefsProvider.overrideWithValue(prefs)],
  );
  addTearDown(c.dispose);
  return c;
}

/// Holds the launch-time read until the test releases it — the only way to
/// make a switch land *before* the Keychain answers (a cold push tap).
class _SlowPrefs implements BoardPrefs {
  _SlowPrefs(this.stored);

  final String? stored;
  final gate = Completer<void>();
  String? written;

  @override
  Future<String?> readLastBoardSlug() async {
    await gate.future;
    return stored;
  }

  @override
  Future<void> writeLastBoardSlug(String slug) async => written = slug;

  @override
  Future<void> clear() async => written = null;
}

void main() {
  test('restores the remembered board from BoardPrefs', () async {
    final c = containerWith(InMemoryBoardPrefs('marketing-site'));

    expect(c.read(currentBoardProvider).restored, isFalse);
    await c.read(currentBoardProvider.notifier).ready;

    final s = c.read(currentBoardProvider);
    expect(s.restored, isTrue);
    expect(s.slug, 'marketing-site');
    expect(s.needsChoice, isFalse);
  });

  test('nothing remembered → restored, needsChoice', () async {
    final c = containerWith(InMemoryBoardPrefs());
    await c.read(currentBoardProvider.notifier).ready;

    expect(c.read(currentBoardProvider).slug, isNull);
    expect(c.read(currentBoardProvider).needsChoice, isTrue);
  });

  test('switchTo makes the board current app-wide and persists it', () async {
    final prefs = InMemoryBoardPrefs('marketing-site');
    final c = containerWith(prefs);
    await c.read(currentBoardProvider.notifier).ready;
    final seen = <String?>[];
    c.listen(currentBoardProvider, (_, next) => seen.add(next.slug));

    await c.read(currentBoardProvider.notifier).switchTo('data-pipeline');

    expect(c.read(currentBoardProvider).slug, 'data-pipeline');
    expect(prefs.slug, 'data-pipeline');
    expect(seen, ['data-pipeline']);
  });

  test('clear forgets the board in memory and in the Keychain', () async {
    final prefs = InMemoryBoardPrefs('marketing-site');
    final c = containerWith(prefs);
    await c.read(currentBoardProvider.notifier).ready;

    await c.read(currentBoardProvider.notifier).clear();

    expect(c.read(currentBoardProvider).needsChoice, isTrue);
    expect(prefs.slug, isNull);
  });

  test(
    'a switch made before the launch read lands is not overwritten by it',
    () async {
      final prefs = _SlowPrefs('old-board');
      final c = containerWith(prefs);
      c.read(currentBoardProvider); // starts the (held) restore

      await c.read(currentBoardProvider.notifier).switchTo('new-board');
      prefs.gate.complete();
      await pumpEventQueue();

      expect(c.read(currentBoardProvider).slug, 'new-board');
      expect(prefs.written, 'new-board');
    },
  );

  group('reconcile', () {
    test('keeps a remembered board that is still listed', () async {
      final c = containerWith(InMemoryBoardPrefs('alpha'));
      await c.read(currentBoardProvider.notifier).ready;

      await c.read(currentBoardProvider.notifier).reconcile(['alpha', 'beta']);

      expect(c.read(currentBoardProvider).slug, 'alpha');
    });

    test(
      'clears a remembered board that is gone (deleted / revoked)',
      () async {
        final prefs = InMemoryBoardPrefs('gone');
        final c = containerWith(prefs);
        await c.read(currentBoardProvider.notifier).ready;

        await c.read(currentBoardProvider.notifier).reconcile([
          'alpha',
          'beta',
        ]);

        expect(c.read(currentBoardProvider).needsChoice, isTrue);
        expect(prefs.slug, isNull);
      },
    );

    test('auto-selects the only board when nothing is remembered', () async {
      final prefs = InMemoryBoardPrefs();
      final c = containerWith(prefs);
      await c.read(currentBoardProvider.notifier).ready;

      await c.read(currentBoardProvider.notifier).reconcile(['only']);

      expect(c.read(currentBoardProvider).slug, 'only');
      expect(prefs.slug, 'only');
    });

    test(
      'leaves nothing chosen with several boards and none remembered',
      () async {
        final c = containerWith(InMemoryBoardPrefs());
        await c.read(currentBoardProvider.notifier).ready;

        await c.read(currentBoardProvider.notifier).reconcile([
          'alpha',
          'beta',
        ]);

        expect(c.read(currentBoardProvider).needsChoice, isTrue);
      },
    );
  });
}
