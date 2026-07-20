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
      'stage': 'Code',
      'questions': [
        {
          'prompt': 'Column order?',
          'options': ['A', 'B'],
        },
      ],
    });
    expect(row.kind, 'needs_input');
    expect(row.kindLabel, 'NEEDS INPUT');
    expect(row.stage, 'Code');
    expect(row.questions, hasLength(1));
    expect(row.questions!.single.prompt, 'Column order?');
    expect(row.questions!.single.options, ['A', 'B']);
  });

  test('a question fills the same defaults as Cards.normalize_question/1', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'status': 'needs_input',
      'kind': 'needs_input',
      'questions': [
        {'prompt': 'Column order?'},
        {
          'prompt': 'Which region?',
          'options': ['us', 'eu'],
          'allow_text': false,
        },
      ],
    });

    // normalize_question/1: options || [], allow_text defaults true. The native
    // stepper must read a question exactly as the web stepper does.
    expect(row.questions![0].options, isEmpty);
    expect(row.questions![0].allowText, isTrue);
    expect(row.questions![1].options, ['us', 'eu']);
    expect(row.questions![1].allowText, isFalse);
  });

  test('a row with no stage parses rather than throwing', () {
    expect(FeedRow.fromJson(reviewRowJson()).stage, isNull);
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

  test('parses stage_group, which groups a sub-lane card under its parent', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'stage': 'Code · Review',
      'stage_group': {'name': 'Code', 'type': 'work'},
    });

    expect(row.stage, 'Code · Review');
    expect(row.stageGroup!.name, 'Code');
    expect(row.stageGroup!.type, 'work');
  });

  test(
    'an absent stage_group parses to null — an older server still renders',
    () {
      expect(FeedRow.fromJson(reviewRowJson()).stageGroup, isNull);
      expect(
        FeedRow.fromJson({...reviewRowJson(), 'stage_group': null}).stageGroup,
        isNull,
      );
    },
  );

  test('a malformed stage_group parses to null rather than throwing', () {
    // No name at all, an empty name, and a wholly wrong shape.
    expect(
      FeedRow.fromJson({
        ...reviewRowJson(),
        'stage_group': {'type': 'work'},
      }).stageGroup,
      isNull,
    );
    expect(
      FeedRow.fromJson({
        ...reviewRowJson(),
        'stage_group': {'name': ''},
      }).stageGroup,
      isNull,
    );
    expect(
      FeedRow.fromJson({...reviewRowJson(), 'stage_group': 'Code'}).stageGroup,
      isNull,
    );
  });

  test('a stage_group with no type parses with an empty type, not a throw', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'stage_group': {'name': 'Code'},
    });
    expect(row.stageGroup!.name, 'Code');
    expect(row.stageGroup!.type, '');
  });

  test('stage_group carries the stage position the inbox orders groups by', () {
    final row = FeedRow.fromJson({
      ...reviewRowJson(),
      'stage_group': {'name': 'Code', 'type': 'work', 'position': 2},
    });

    expect(row.stageGroup!.position, 2);
  });

  test(
    'a stage_group with no position defaults to the unknown sentinel, not a throw',
    () {
      // A server between PR #137 and this change ships name+type but no position.
      final row = FeedRow.fromJson({
        ...reviewRowJson(),
        'stage_group': {'name': 'Code', 'type': 'work'},
      });

      expect(row.stageGroup!.position, FeedStageGroup.unknownPosition);
    },
  );
}
