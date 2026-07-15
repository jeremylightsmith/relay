import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// The persistent approve/reject bar — CORE-03 "Card · review" in
/// `docs/designs/Relay Mobile.dc.html` (line 188), matched to its **bottom bar only**:
/// the artboard's breadcrumb, native title, owner badge, summary card, chips and comment
/// field are all V1.1, and everything above this bar is the embedded LiveView body.
///
/// Hosted by [CardScreen] as the Scaffold's `bottomNavigationBar` — outside the webview's
/// scroll, which is what makes it persistent (brief §04: "you never lose the approve/reject
/// bar").
///
/// **Surface only (RLY-87).** The callbacks are what RLY-88 replaces; it should not have to
/// restructure this widget.
class CardReviewBar extends StatelessWidget {
  const CardReviewBar({
    super.key,
    required this.onApprove,
    required this.onReject,
  });

  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        // The mockup paints bar and Reject button the same oklch(1 0 0); read one token
        // for both so they can never drift into two different whites.
        color: scheme.surface,
        border: const Border(top: BorderSide(color: RelayTheme.relayHairline)),
      ),
      child: SafeArea(
        top: false,
        // The mockup's own 20px bottom padding is the home indicator's clearance;
        // SafeArea supplies the device's real inset instead.
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                flex: 10, // mockup flex:1
                child: OutlinedButton(
                  key: const Key('card_reject'),
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: scheme.surface,
                    foregroundColor: RelayTheme.relayRejectLabel,
                    side: const BorderSide(color: RelayTheme.relayRejectBorder),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 8), // mockup gap:8px
              Expanded(
                flex:
                    14, // mockup flex:1.4 — Approve reads as the primary action
                child: FilledButton(
                  key: const Key('card_approve'),
                  onPressed: onApprove,
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
