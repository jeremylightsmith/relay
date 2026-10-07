/// Client-side prev/next context for the card host's ‹ › buttons (RE400; born as
/// RLY-234's swipe context, Decision 2).
///
/// The originating screen (a board column or the needs-you feed) hands `CardScreen`
/// the ordered list of surrounding cards plus which one is showing, so prev/next is a
/// local lookup — no per-tap network. Carried via go_router `extra` (in-memory):
/// absent on a cold deep link / push, where ‹ › are inert (a single card).
library;

/// One card in a nav context: enough to route to it and pick its review bar.
class CardNavItem {
  const CardNavItem({required this.ref, required this.boardSlug, this.kind});

  final String ref;
  final String boardSlug;

  /// `in_review` | `needs_input` | `failed` | null — drives CardScreen's bottom bar
  /// after a ‹ › move (null → no bar), same contract as the query-param `kind`.
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

  /// The neighbor in [direction] — [prev] or [next].
  CardNavItem? neighbor(CardNavDirection direction) => switch (direction) {
    CardNavDirection.prev => prev,
    CardNavDirection.next => next,
  };

  /// Re-center this context on [ref] (same list, moved index) after a ‹ › move. Null if
  /// [ref] isn't in the list.
  CardNavContext? at(String ref) => seed(items: items, currentRef: ref);

  /// Build a context from an ordered [items] list, seeking to [currentRef]. Null when
  /// the list is empty or does not contain [currentRef] — i.e. no neighbors, ‹ › inert.
  static CardNavContext? seed({
    required List<CardNavItem> items,
    required String currentRef,
  }) {
    final i = items.indexWhere((it) => it.ref == currentRef);
    return i < 0 ? null : CardNavContext(items: items, index: i);
  }
}

/// A ‹ › step through a [CardNavContext]. `.name` is the wire token the web
/// chevrons send over `relayCardNav` and the card URL's `nav` param carries — the
/// only Dart copy of `"prev"` / `"next"`.
enum CardNavDirection { prev, next }
