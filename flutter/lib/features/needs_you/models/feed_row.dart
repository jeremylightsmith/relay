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

/// One structured question from RLY-71's `meta["questions"]`, as FeedJSON ships it.
///
/// The defaults mirror `Cards.normalize_question/1` **exactly** — an absent `options`
/// is `[]`, an absent or null `allow_text` is `true` — so the native stepper and the
/// web stepper read one identical question.
class FeedQuestion {
  const FeedQuestion({
    required this.prompt,
    required this.options,
    required this.allowText,
  });

  final String prompt;

  /// Plain strings — RLY-71's merged wire format has no per-option description (D3).
  final List<String> options;

  /// `allow_text` on the wire. NOT `allow_free_text`, which exists nowhere in Relay.
  final bool allowText;

  factory FeedQuestion.fromJson(Map<String, dynamic> json) => FeedQuestion(
    prompt: json['prompt'] as String? ?? '',
    options: ((json['options'] as List<dynamic>?) ?? const [])
        .map((e) => e.toString())
        .toList(growable: false),
    allowText: json['allow_text'] as bool? ?? true,
  );
}

/// The **top-level** stage a row files under (RLY-156). A card in `Code · Review` and a
/// card in `Code` both carry `{name: "Code", type: "work", position: <Code's>}`, so
/// sub-lane cards group with their parent — same name, same colour, same board place.
class FeedStageGroup {
  const FeedStageGroup({
    required this.name,
    required this.type,
    this.position = unknownPosition,
  });

  final String name;

  /// The stage's behaviour type: `queue | work | planning | review | done`. Deliberately a
  /// String, not an enum — a type added server-side must not break an older build. The
  /// unknown case is handled by [RelayTheme.stageTypeColor]'s fallback.
  final String type;

  /// The top-level stage's `position` — the board order the inbox renders groups in
  /// (RLY-156 re-plan: a reviewer asked for stage order, not recency). [unknownPosition]
  /// when the server sent no position (a build between PR #137 and this change): such
  /// groups sort after positioned ones and fall back to first-appearance among themselves.
  final int position;

  /// Sentinel for "the server sent no position". Far above any real stage position
  /// (top-level stages number 1..n), so unknown-position groups sink to the bottom.
  static const int unknownPosition = 1 << 30;

  /// Null when the field is absent (an older server), malformed, or carries no name —
  /// the inbox then files the row into its trailing unlabelled group rather than throwing.
  static FeedStageGroup? fromJson(Map<String, dynamic>? json) {
    final name = json?['name'] as String?;
    if (name == null || name.isEmpty) return null;
    return FeedStageGroup(
      name: name,
      type: json?['type'] as String? ?? '',
      position: json?['position'] as int? ?? unknownPosition,
    );
  }
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
    this.stage,
    this.reason,
    this.questions,
    this.stageGroup,
  });

  final String ref;
  final String title;
  final FeedBoard board;
  final String? tag;

  /// The stage's display name (`Code`, `Code · Review`) — INPUT-01's breadcrumb.
  final String? stage;

  /// The top-level stage this row groups under (RLY-156). Null on an older server.
  final FeedStageGroup? stageGroup;

  /// The card's status. Present for completeness; the two-type contract reads [kind].
  final String status;

  /// `needs_input` | `in_review`. The server emits this equal to status *by design*,
  /// so the mobile contract can't silently follow the board's wider needs-you rollup.
  final String kind;

  final String? reason;
  final DateTime blockedAt;

  /// Structured questions on a needs_input row; null on in_review rows and on a card
  /// blocked with a plain-string question (the legacy free-text path).
  final List<FeedQuestion>? questions;

  /// The mono uppercase label HOME-01 draws.
  String get kindLabel => kind == 'needs_input' ? 'NEEDS INPUT' : 'REVIEW';

  factory FeedRow.fromJson(Map<String, dynamic> json) => FeedRow(
    ref: json['ref'] as String,
    title: json['title'] as String? ?? '',
    board: FeedBoard.fromJson(
      (json['board'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    tag: json['tag'] as String?,
    stage: json['stage'] as String?,
    status: json['status'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    reason: json['reason'] as String?,
    blockedAt: _parseBlockedAt(json['blocked_at'] as String?),
    questions: (json['questions'] as List<dynamic>?)
        ?.map((e) => FeedQuestion.fromJson((e as Map).cast<String, dynamic>()))
        .toList(growable: false),
    stageGroup: FeedStageGroup.fromJson(switch (json['stage_group']) {
      final Map m => m.cast<String, dynamic>(),
      _ => null,
    }),
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

/// One rendered group in the inbox: a stage bar and the rows filed under it (RLY-156).
class InboxGroup {
  const InboxGroup({required this.group, required this.rows});

  /// Null for the trailing catch-all group — rows the server sent with no `stage_group`.
  final FeedStageGroup? group;

  final List<FeedRow> rows;
}

/// Regroup [rows] for rendering (RLY-156). **A stable re-sort of the groups, never of the
/// rows** — server order (most-recently-blocked first) is authoritative *inside* a group:
///
/// - rows keep server order inside their group;
/// - **groups render in board order — the top-level stage's [FeedStageGroup.position]** —
///   so an earlier stage sits above a later one even when the later one holds the more
///   recently blocked card (a reviewer's re-plan ask). Ties — same position across two
///   merged boards, or an older server that sent no position — fall back to first
///   appearance, keeping the order deterministic;
/// - rows with a null [FeedRow.stageGroup] collect into one trailing unlabelled group, so
///   an older server or an odd row still renders.
///
/// The feed spans **every** board the user belongs to, so same-named stages on different
/// boards **merge into one group** — [InboxRow]'s board chip is what tells them apart, so
/// no group is duplicated per board. If merged rows disagree on `type` or `position`, the
/// first row wins: deterministic, and cosmetic only.
List<InboxGroup> groupRowsByStage(List<FeedRow> rows) {
  final order = <String>[]; // first-appearance order — the tie-breaker
  final rowsByName = <String, List<FeedRow>>{};
  final groupsByName = <String, FeedStageGroup>{};
  final ungrouped = <FeedRow>[];

  for (final row in rows) {
    final group = row.stageGroup;
    if (group == null) {
      ungrouped.add(row);
      continue;
    }
    if (!rowsByName.containsKey(group.name)) {
      order.add(group.name);
      rowsByName[group.name] = <FeedRow>[];
      groupsByName[group.name] =
          group; // first row wins — for type AND position
    }
    rowsByName[group.name]!.add(row);
  }

  final names = [...order]
    ..sort((a, b) {
      final byPosition = groupsByName[a]!.position.compareTo(
        groupsByName[b]!.position,
      );
      return byPosition != 0
          ? byPosition
          : order.indexOf(a).compareTo(order.indexOf(b));
    });

  return [
    for (final name in names)
      InboxGroup(group: groupsByName[name], rows: rowsByName[name]!),
    if (ungrouped.isNotEmpty) InboxGroup(group: null, rows: ungrouped),
  ];
}
