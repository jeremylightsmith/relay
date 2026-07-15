/// Value types mirroring RelayWeb.Api.FeedJSON's row shape (RLY-80, merged).
/// Pure: no HTTP, no Flutter. Absent/unknown fields parse to null rather than throw —
/// `questions` is null on in_review rows and `meta.working_count` does not exist yet.
library;

class FeedBoard {
  const FeedBoard({required this.name, required this.key, required this.slug});

  final String name;
  final String key;
  final String slug;

  factory FeedBoard.fromJson(Map<String, dynamic> json) => FeedBoard(
    name: json['name'] as String? ?? '',
    key: json['key'] as String? ?? '',
    slug: json['slug'] as String? ?? '',
  );
}

class FeedRow {
  const FeedRow({
    required this.ref,
    required this.title,
    required this.board,
    required this.status,
    required this.kind,
    required this.blockedAt,
    this.tag,
    this.reason,
    this.questions,
  });

  final String ref;
  final String title;
  final FeedBoard board;
  final String? tag;

  /// The card's status. Present for completeness; the two-type contract reads [kind].
  final String status;

  /// `needs_input` | `in_review`. The server emits this equal to status *by design*,
  /// so the mobile contract can't silently follow the board's wider needs-you rollup.
  final String kind;

  final String? reason;
  final DateTime blockedAt;
  final List<dynamic>? questions;

  /// The mono uppercase label HOME-01 draws.
  String get kindLabel => kind == 'needs_input' ? 'NEEDS INPUT' : 'REVIEW';

  factory FeedRow.fromJson(Map<String, dynamic> json) => FeedRow(
    ref: json['ref'] as String,
    title: json['title'] as String? ?? '',
    board: FeedBoard.fromJson(
      (json['board'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    tag: json['tag'] as String?,
    status: json['status'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    reason: json['reason'] as String?,
    blockedAt: _parseBlockedAt(json['blocked_at'] as String?),
    questions: json['questions'] as List<dynamic>?,
  );
}

/// Phoenix renders `blocked_at` from a naive **UTC** timestamp, so the JSON usually
/// carries no zone marker. DateTime.parse would then read it as *local* time and the
/// age would be off by the device's UTC offset — so re-stamp a zone-less value as UTC.
DateTime _parseBlockedAt(String? raw) {
  if (raw == null) return DateTime.now().toUtc();
  final parsed = DateTime.parse(raw);
  if (parsed.isUtc) return parsed;
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
    parsed.millisecond,
    parsed.microsecond,
  );
}

class FeedMeta {
  const FeedMeta({required this.count, this.workingCount});

  final int count;

  /// D1: null until a follow-up on RLY-80 adds it. Null or 0 hides the working strip.
  final int? workingCount;

  factory FeedMeta.fromJson(Map<String, dynamic>? json) => FeedMeta(
    count: (json?['count'] as int?) ?? 0,
    workingCount: json?['working_count'] as int?,
  );
}

class FeedPage {
  const FeedPage({required this.rows, required this.meta});

  final List<FeedRow> rows;
  final FeedMeta meta;

  factory FeedPage.fromJson(Map<String, dynamic> json) => FeedPage(
    rows: ((json['data'] as List<dynamic>?) ?? const [])
        .map((e) => FeedRow.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false),
    meta: FeedMeta.fromJson((json['meta'] as Map?)?.cast<String, dynamic>()),
  );
}

/// The right-aligned mono age HOME-01 draws (`4m`, `1h`, `3d`).
String formatAge(DateTime blockedAt, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).toUtc().difference(blockedAt.toUtc());
  if (delta.inMinutes < 1) return 'now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m';
  if (delta.inHours < 24) return '${delta.inHours}h';
  return '${delta.inDays}d';
}
