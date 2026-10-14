import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/tabs.dart';
import 'package:relay_mobile/features/board/last_place.dart';

ProviderContainer containerWith(LastPlaceStore store) {
  final c = ProviderContainer(
    overrides: [lastPlaceStoreProvider.overrideWithValue(store)],
  );
  addTearDown(c.dispose);
  return c;
}

/// Holds the launch-time read until the test releases it — the only way to
/// make a write land *before* the Keychain answers.
class _SlowStore extends InMemoryLastPlaceStore {
  _SlowStore(super.place);

  final gate = Completer<void>();

  @override
  Future<LastPlace?> read() async {
    final stored = place;
    await gate.future;
    return stored;
  }
}

void main() {
  group('LastPlace', () {
    test('round-trips through JSON with the exact keys', () {
      const place = LastPlace(
        tab: AppTab.board,
        stageId: 12,
        stageName: 'Spec',
        cardRef: 'RE440',
      );

      final json = place.toJson();

      expect(json, {
        'tab': 'board',
        'stage_id': 12,
        'stage_name': 'Spec',
        'card_ref': 'RE440',
      });
      expect(LastPlace.fromJson(json), place);
      expect(LastPlace.fromJson(json).hashCode, place.hashCode);
    });

    test('fromJson rejects anything without a known tab', () {
      for (final bad in <Object?>[
        null,
        'garbage',
        <String, Object?>{},
        {'tab': 'inbox'},
      ]) {
        expect(LastPlace.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('fromJson reads a wrong-typed optional field as null', () {
      expect(
        LastPlace.fromJson({'tab': 'settings', 'stage_id': 'x'}),
        const LastPlace(tab: AppTab.settings),
      );
    });
  });

  test(
    'SecureLastPlaceStore degrades to null when the platform is unavailable',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // `flutter test` has no Keychain platform channel: every method must
      // swallow the error — a storage hiccup means "nothing remembered".
      final store = SecureLastPlaceStore();

      await store.write(const LastPlace(tab: AppTab.board, stageId: 1));
      expect(await store.read(), isNull);
      await store.clear();
    },
  );

  group('LastPlaceController', () {
    test('restores the remembered place and hands the launch place out '
        'once', () async {
      final c = containerWith(
        InMemoryLastPlaceStore(const LastPlace(tab: AppTab.settings)),
      );

      expect(c.read(lastPlaceProvider).restored, isFalse);
      await c.read(lastPlaceProvider.notifier).ready;

      final s = c.read(lastPlaceProvider);
      expect(s.restored, isTrue);
      expect(s.place, const LastPlace(tab: AppTab.settings));
      final controller = c.read(lastPlaceProvider.notifier);
      expect(
        controller.takeLaunchPlace(),
        const LastPlace(tab: AppTab.settings),
      );
      expect(controller.takeLaunchPlace(), isNull);
    });

    test(
      'recordStage with nothing remembered lands on the Board tab',
      () async {
        final store = InMemoryLastPlaceStore();
        final c = containerWith(store);
        await c.read(lastPlaceProvider.notifier).ready;

        await c.read(lastPlaceProvider.notifier).recordStage(7, 'Code');

        const expected = LastPlace(
          tab: AppTab.board,
          stageId: 7,
          stageName: 'Code',
        );
        expect(c.read(lastPlaceProvider).place, expected);
        expect(store.place, expected);
      },
    );

    test('each mutation keeps exactly what it should', () async {
      final store = InMemoryLastPlaceStore(
        const LastPlace(
          tab: AppTab.board,
          stageId: 7,
          stageName: 'Code',
          cardRef: 'RE1',
        ),
      );
      final c = containerWith(store);
      final controller = c.read(lastPlaceProvider.notifier);
      await controller.ready;
      LastPlace? place() => c.read(lastPlaceProvider).place;

      await controller.recordTab(AppTab.needsYou);
      expect(
        place(),
        const LastPlace(tab: AppTab.needsYou, stageId: 7, stageName: 'Code'),
      );

      await controller.recordBoardCard('RE2');
      expect(
        place(),
        const LastPlace(
          tab: AppTab.board,
          stageId: 7,
          stageName: 'Code',
          cardRef: 'RE2',
        ),
      );

      await controller.forgetCard();
      expect(
        place(),
        const LastPlace(tab: AppTab.board, stageId: 7, stageName: 'Code'),
      );

      await controller.forgetBoardPosition();
      expect(place(), const LastPlace(tab: AppTab.board));
      expect(store.place, const LastPlace(tab: AppTab.board));

      await controller.forget();
      expect(place(), isNull);
      expect(store.place, isNull);
    });

    test('a write made before the launch read lands wins over it, but the '
        'launch place is still what was read', () async {
      const stored = LastPlace(
        tab: AppTab.board,
        stageId: 3,
        stageName: 'Spec',
        cardRef: 'RE9',
      );
      final store = _SlowStore(stored);
      final c = containerWith(store);
      final controller = c.read(lastPlaceProvider.notifier);

      await controller.recordTab(AppTab.settings);
      store.gate.complete();
      await pumpEventQueue();

      expect(c.read(lastPlaceProvider).place!.tab, AppTab.settings);
      expect(c.read(lastPlaceProvider).restored, isTrue);
      expect(controller.takeLaunchPlace(), stored);
    });

    test(
      'forget before the launch read lands drops the launch place',
      () async {
        final store = _SlowStore(
          const LastPlace(
            tab: AppTab.board,
            stageId: 3,
            stageName: 'Spec',
            cardRef: 'RE9',
          ),
        );
        final c = containerWith(store);
        final controller = c.read(lastPlaceProvider.notifier);

        await controller.forget();
        store.gate.complete();
        await pumpEventQueue();

        expect(c.read(lastPlaceProvider).place, isNull);
        expect(controller.takeLaunchPlace(), isNull);
      },
    );
  });
}
