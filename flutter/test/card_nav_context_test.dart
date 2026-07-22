import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/card/card_nav_context.dart';

void main() {
  group('CardNavContext.seed', () {
    const items = [
      CardNavItem(ref: 'RLY-1', boardSlug: 'relay'),
      CardNavItem(ref: 'RLY-2', boardSlug: 'relay', kind: 'in_review'),
      CardNavItem(ref: 'RLY-3', boardSlug: 'relay'),
    ];

    test('seeks to the current ref and exposes prev/next', () {
      final ctx = CardNavContext.seed(items: items, currentRef: 'RLY-2');
      expect(ctx, isNotNull);
      expect(ctx!.index, 1);
      expect(ctx.prev?.ref, 'RLY-1');
      expect(ctx.next?.ref, 'RLY-3');
      expect(ctx.next?.boardSlug, 'relay');
    });

    test('at a boundary the missing neighbor is null (no wrap)', () {
      expect(
        CardNavContext.seed(items: items, currentRef: 'RLY-1')!.prev,
        isNull,
      );
      expect(
        CardNavContext.seed(items: items, currentRef: 'RLY-3')!.next,
        isNull,
      );
    });

    test('returns null when the list is empty or the ref is absent', () {
      expect(CardNavContext.seed(items: const [], currentRef: 'RLY-1'), isNull);
      expect(
        CardNavContext.seed(
          items: const [CardNavItem(ref: 'RLY-9', boardSlug: 'relay')],
          currentRef: 'RLY-1',
        ),
        isNull,
      );
    });

    test('at(ref) re-centers on a neighbor, keeping the same list', () {
      final ctx = CardNavContext.seed(
        items: items,
        currentRef: 'RLY-1',
      )!.at('RLY-2');
      expect(ctx, isNotNull);
      expect(ctx!.index, 1);
      expect(ctx.prev?.ref, 'RLY-1');
      expect(ctx.next?.ref, 'RLY-3');
    });
  });
}
