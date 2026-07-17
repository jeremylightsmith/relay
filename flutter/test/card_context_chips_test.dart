import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/card/widgets/card_context_chips.dart';

Future<void> pumpChips(WidgetTester tester, {VoidCallback? onOpenPr}) {
  return tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: CardContextChips(onOpenPr: onOpenPr ?? () {}),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'matches the CORE-03 chip row: strip, border, radius, tile, glyph, label',
    (tester) async {
      await pumpChips(tester);

      // Strip: surface with the shared hairline top border.
      final strip = tester.widget<DecoratedBox>(
        find.byKey(const Key('card_context_chips')),
      );
      final stripDeco = strip.decoration as BoxDecoration;
      expect((stripDeco.border! as Border).top.color, RelayTheme.relayHairline);

      // Chip: 1px oklch(0.9 0.006 255) border, 10px corner radius.
      final chip = tester.widget<Material>(
        find.byKey(const Key('card_pr_chip')),
      );
      final shape = chip.shape! as RoundedRectangleBorder;
      expect(shape.side.color, RelayTheme.relayChipBorder);
      expect(shape.borderRadius, BorderRadius.circular(10));

      // Icon tile: 22×22 rounded square (7px radius), near-black oklch(0.2 0.01 260).
      expect(
        tester.getSize(find.byKey(const Key('card_pr_chip_tile'))),
        const Size(22, 22),
      );
      final tile = tester.widget<Container>(
        find.byKey(const Key('card_pr_chip_tile')),
      );
      final tileDeco = tile.decoration! as BoxDecoration;
      expect(tileDeco.color, RelayTheme.relayPrChipTile);
      expect(tileDeco.borderRadius, BorderRadius.circular(7));

      // Glyph: the artboard's 10×10 white circle outline, 1.8px stroke.
      expect(
        tester.getSize(find.byKey(const Key('card_pr_chip_glyph'))),
        const Size(10, 10),
      );
      final glyph = tester.widget<Container>(
        find.byKey(const Key('card_pr_chip_glyph')),
      );
      final glyphDeco = glyph.decoration! as BoxDecoration;
      expect(glyphDeco.shape, BoxShape.circle);
      expect((glyphDeco.border! as Border).top.color, Colors.white);
      expect((glyphDeco.border! as Border).top.width, 1.8);

      // Label: "PR ↗", 11px / w600, oklch(0.3 0.02 255).
      final label = tester.widget<Text>(find.text('PR ↗'));
      expect(label.style?.fontSize, 11);
      expect(label.style?.fontWeight, FontWeight.w600);
      expect(label.style?.color, RelayTheme.relayChipLabel);
    },
  );

  testWidgets('tapping the chip fires onOpenPr', (tester) async {
    var taps = 0;
    await pumpChips(tester, onOpenPr: () => taps++);

    await tester.tap(find.byKey(const Key('card_pr_chip')));

    expect(taps, 1);
  });
}
