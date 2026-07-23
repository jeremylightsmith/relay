/// Client-side swipe-navigation context for the card host (RLY-234, Decision 2).
///
/// The originating screen (a board column or the needs-you feed) hands `CardScreen`
/// the ordered list of surrounding cards plus which one is showing, so prev/next is a
/// local lookup — no per-swipe network. Carried via go_router `extra` (in-memory):
/// absent on a cold deep link / push, where swipe is inert (a single card).
library;

/// One card in a swipe context: enough to route to it and pick its review bar.
class CardNavItem {
  const CardNavItem({required this.ref, required this.boardSlug, this.kind});

  final String ref;
  final String boardSlug;

  /// `in_review` | `needs_input` | `failed` | null — drives CardScreen's bottom bar
  /// after a swipe (null → no bar), same contract as the query-param `kind`.
  final String? kind;
}

/// An ordered list of the cards surrounding the one on screen, plus the current index.
class CardNavContext {
  const CardNavContext({required this.items, required this.index});

  final List<CardNavItem> items;
  final int index;

  /// The card before the current one, or null at the start of the list (no wrap).
  CardNavItem? get prev => index > 0 ? items[index - 1] : null;

  /// The card after the current one, or null at the end of the list (no wrap).
  CardNavItem? get next => index + 1 < items.length ? items[index + 1] : null;

  /// Re-center this context on [ref] (same list, moved index) after a swipe. Null if
  /// [ref] isn't in the list.
  CardNavContext? at(String ref) => seed(items: items, currentRef: ref);

  /// Build a context from an ordered [items] list, seeking to [currentRef]. Null when
  /// the list is empty or does not contain [currentRef] — i.e. no neighbors, swipe inert.
  static CardNavContext? seed({
    required List<CardNavItem> items,
    required String currentRef,
  }) {
    final i = items.indexWhere((it) => it.ref == currentRef);
    return i < 0 ? null : CardNavContext(items: items, index: i);
  }
}
