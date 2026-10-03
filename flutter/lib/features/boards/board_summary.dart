/// One row of `GET /api/all/boards` (RE376) — mirrors RelayWeb.Api.BoardListJSON.
/// Pure: no HTTP, no Flutter. Absent fields parse to neutral defaults rather than throw.
class BoardSummary {
  const BoardSummary({
    required this.name,
    required this.slug,
    required this.key,
    required this.needsYouCount,
    required this.stageCount,
    required this.cardCount,
    required this.aiActive,
  });

  final String name;
  final String slug;
  final String key;

  /// The server's two-type needs-you count (ADR 0005), incl. agent_stalled.
  final int needsYouCount;
  final int stageCount;
  final int cardCount;
  final bool aiActive;

  factory BoardSummary.fromJson(Map<String, dynamic> json) => BoardSummary(
    name: json['name'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
    key: json['key'] as String? ?? '',
    needsYouCount: json['needs_you_count'] as int? ?? 0,
    stageCount: json['stage_count'] as int? ?? 0,
    cardCount: json['card_count'] as int? ?? 0,
    aiActive: json['ai_active'] as bool? ?? false,
  );

  /// BOARDS-00's meta line — the same text the web boards list draws.
  String get metaLabel =>
      '$stageCount stages · $cardCount cards · ${aiActive ? 'AI active' : 'idle'}';
}
