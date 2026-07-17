import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// The native context-chip strip — the CORE-03 "Card · review" chip row in
/// `docs/designs/Relay Mobile.dc.html` (the Spec / "PR ↗" chips, lines ~179–181).
/// Today it renders only the PR chip (RLY-98); it is a plain Row of Expanded chips so
/// RLY-91's Spec chip joins the strip without restructuring.
///
/// Hosted by [CardScreen] in the Scaffold's bottom chrome, above the review bar —
/// outside the webview's scroll, present for every entry path (review queue, board tap,
/// needs-input row, push deep link). The host only builds it when the card has a
/// launchable pr_url, so the strip itself has no empty state.
class CardContextChips extends StatelessWidget {
  const CardContextChips({super.key, required this.onOpenPr});

  /// PR-chip tap. Null renders the chip disabled; in practice the host always passes a
  /// handler — no strip without a pr_url.
  final VoidCallback? onOpenPr;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      key: const Key('card_context_chips'),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: const Border(top: BorderSide(color: RelayTheme.relayHairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [Expanded(child: _PrChip(onTap: onOpenPr))],
        ),
      ),
    );
  }
}

/// One chip, matched to the artboard: white surface, 1px hairline border, 10px radius,
/// 9×10px padding, a 22×22 rounded-square icon tile (7px radius) and an 11px/w600
/// label. The PR mark is the artboard's white circle outline on a near-black tile.
class _PrChip extends StatelessWidget {
  const _PrChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      key: const Key('card_pr_chip'),
      color: scheme.surface, // mockup background: oklch(1 0 0)
      shape: RoundedRectangleBorder(
        // mockup: 1px solid oklch(0.9 0.006 255), border-radius 10px
        side: const BorderSide(color: RelayTheme.relayChipBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          // mockup padding: 9px 10px
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            children: [
              Container(
                key: const Key('card_pr_chip_tile'),
                width: 22, // mockup 22×22 icon tile
                height: 22,
                decoration: BoxDecoration(
                  color: RelayTheme.relayPrChipTile,
                  borderRadius: BorderRadius.circular(7), // mockup 7px
                ),
                alignment: Alignment.center,
                child: Container(
                  key: const Key('card_pr_chip_glyph'),
                  width: 10, // mockup 10×10 circle outline
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.8),
                  ),
                ),
              ),
              const SizedBox(width: 7), // mockup gap: 7px
              const Text(
                'PR ↗',
                style: TextStyle(
                  fontSize: 11, // mockup 11px / weight 600
                  fontWeight: FontWeight.w600,
                  color: RelayTheme.relayChipLabel,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
