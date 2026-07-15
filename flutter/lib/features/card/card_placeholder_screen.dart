import 'package:flutter/material.dart';

/// **TEMPORARY (RLY-85 · D4). RLY-87 deletes this file and its route.**
///
/// The inbox pushes `/card/:ref?kind=…`, but RLY-87 — which owns the real card-detail
/// host (embedded chromeless LiveView body + persistent action bar) — has not landed.
/// Rather than block RLY-85 on it, this stub makes the tap resolve and shows that the
/// ref and kind round-trip.
///
/// This is **not** a card surface and must not grow into one: no card content, no
/// action bar. It exists only so RLY-85 ships independently.
///
/// Note: this is deliberately distinct from `/cards/:ref` → [CardScreen], which is
/// RLY-81's push deep-link into the F3 embedded LiveView. Leave that route alone.
class CardPlaceholderScreen extends StatelessWidget {
  const CardPlaceholderScreen({
    super.key,
    required this.cardRef,
    required this.kind,
  });

  final String cardRef;

  /// `needs_input` | `in_review` — RLY-87 uses this to pick its bottom bar
  /// (review bar vs RLY-89's answer field).
  final String kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(cardRef)),
      body: Center(
        key: const Key('card_placeholder'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.construction,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Card detail is not built yet',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Temporary placeholder (RLY-85). RLY-87 replaces this route with the '
                'real card-detail surface.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Text(
                'ref: $cardRef\nkind: $kind',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 15,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
