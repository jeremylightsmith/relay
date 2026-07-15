import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';

// Mirrors RelayWeb.Api.FeedJSON's merged row shape. Phoenix renders the naive
// UTC timestamp with no zone marker — the `Z`-less string is deliberate.
Map<String, dynamic> reviewRowJson() => {
  'ref': 'RLY-1',
  'title': 'Rewrite the onboarding tooltips',
  'board': {'name': 'Relay', 'key': 'RLY', 'slug': 'relay'},
  'tag': 'mobile',
  'status': 'in_review',
  'kind': 'in_review',
  'reason': 'Review',
  'blocked_at': '2026-07-15T09:00:00',
  'questions': null,
};

void main() {
  test('parses an in_review row, with questions absent', () {
    final row = FeedRow.fromJson(reviewRowJson());
    expect(row.ref, 'RLY-1');
    expect(row.title, 'Rewrite the onboarding tooltips');
    expect(row.board.key, 'RLY');
    expect(row.board.slug, 'relay');
    expect(row.tag, 'mobile');
    expect(row.kind, 'in_review');
    expect(row.reason, 'Review');
    expect(row.questions, isNull);
    expect(row.kindLabel, 'REVIEW');
  });

  test('parses a needs_input row carrying questions', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'ref': 'RLY-2',
      'status': 'needs_input',
      'kind': 'needs_input',
      'questions': [
        {
          'prompt': 'Column order?',
          'options': ['A', 'B'],
        },
      ],
    });
    expect(row.kind, 'needs_input');
    expect(row.kindLabel, 'NEEDS INPUT');
    expect(row.questions, hasLength(1));
  });

  test('a Z-less blocked_at is read as UTC, not local time', () {
    final row = FeedRow.fromJson(reviewRowJson());
    expect(row.blockedAt.isUtc, isTrue);
    expect(row.blockedAt, DateTime.utc(2026, 7, 15, 9));
  });

  test('an explicit Z offset is honoured', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'blocked_at': '2026-07-15T09:00:00Z',
    });
    expect(row.blockedAt, DateTime.utc(2026, 7, 15, 9));
  });

  test('a null tag and a null reason parse rather than throw', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'tag': null,
      'reason': null,
    });
    expect(row.tag, isNull);
    expect(row.reason, isNull);
  });

  test('meta.working_count is null when the key is absent (F4 as merged)', () {
    final page = FeedPage.fromJson({
      'data': [reviewRowJson()],
      'meta': {'count': 1},
    });
    expect(page.meta.count, 1);
    expect(page.meta.workingCount, isNull);
    expect(page.rows, hasLength(1));
  });

  test('meta.working_count is read when F4 supplies it', () {
    final page = FeedPage.fromJson({
      'data': [],
      'meta': {'count': 0, 'working_count': 3},
    });
    expect(page.meta.workingCount, 3);
  });

  test('rows keep the server order — the client must not re-sort', () {
    final page = FeedPage.fromJson({
      'data': [
        {
          ...reviewRowJson(),
          'ref': 'RLY-9',
          'blocked_at': '2026-07-15T08:00:00',
        },
        {
          ...reviewRowJson(),
          'ref': 'RLY-3',
          'blocked_at': '2026-07-15T09:30:00',
        },
      ],
      'meta': {'count': 2},
    });
    expect(page.rows.map((r) => r.ref), ['RLY-9', 'RLY-3']);
  });

  test('formatAge renders minutes, hours and days', () {
    final now = DateTime.utc(2026, 7, 15, 12);
    expect(formatAge(DateTime.utc(2026, 7, 15, 11, 56), now: now), '4m');
    expect(formatAge(DateTime.utc(2026, 7, 15, 11), now: now), '1h');
    expect(formatAge(DateTime.utc(2026, 7, 12, 12), now: now), '3d');
    expect(formatAge(DateTime.utc(2026, 7, 15, 11, 59, 30), now: now), 'now');
  });
}
