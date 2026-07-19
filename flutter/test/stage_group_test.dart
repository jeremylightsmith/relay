import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';
import 'package:relay_mobile/features/needs_you/widgets/stage_group_header.dart';

FeedRow row(
  String ref, {
  String? group,
  String type = 'work',
  String slug = 'relay',
}) => FeedRow(
  ref: ref,
  title: 'Card $ref',
  board: FeedBoard(name: 'Relay', key: 'RLY', slug: slug),
  status: 'in_review',
  kind: 'in_review',
  blockedAt: DateTime.utc(2026, 7, 15),
  stageGroup: group == null ? null : FeedStageGroup(name: group, type: type),
);

void main() {
  test('rows keep server order inside a group', () {
    final groups = groupRowsByStage([
      row('RLY-1', group: 'Code'),
      row('RLY-2', group: 'Code'),
      row('RLY-3', group: 'Code'),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.group!.name, 'Code');
    expect(groups.single.rows.map((r) => r.ref), ['RLY-1', 'RLY-2', 'RLY-3']);
  });

  test('groups appear in order of first appearance, not alphabetically', () {
    // Server order is most-recently-blocked first, so the group holding the newest
    // block comes first. Spec is in Code, but Code's first row is older.
    final groups = groupRowsByStage([
      row('RLY-1', group: 'Spec', type: 'planning'),
      row('RLY-2', group: 'Code'),
      row('RLY-3', group: 'Spec', type: 'planning'),
    ]);

    expect(groups.map((g) => g.group!.name), ['Spec', 'Code']);
    expect(groups.first.rows.map((r) => r.ref), ['RLY-1', 'RLY-3']);
    expect(groups.last.rows.map((r) => r.ref), ['RLY-2']);
  });

  test('same-named stages on different boards merge into one group', () {
    // The feed spans every board; the per-row board chip is what tells them apart,
    // so a group is never duplicated per board.
    final groups = groupRowsByStage([
      row('AAA-1', group: 'Code', slug: 'alpha'),
      row('BBB-1', group: 'Code', slug: 'beta'),
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.rows.map((r) => r.ref), ['AAA-1', 'BBB-1']);
  });

  test('when merged stages disagree on type the first row wins', () {
    final groups = groupRowsByStage([
      row('AAA-1', group: 'Code', type: 'work'),
      row('BBB-1', group: 'Code', type: 'planning'),
    ]);

    expect(groups.single.group!.type, 'work');
  });

  test('rows with no stage group sink into one trailing unlabelled group', () {
    final groups = groupRowsByStage([
      row('RLY-1'),
      row('RLY-2', group: 'Code'),
      row('RLY-3'),
    ]);

    expect(groups.map((g) => g.group?.name), ['Code', null]);
    expect(groups.last.rows.map((r) => r.ref), ['RLY-1', 'RLY-3']);
  });

  test('an empty feed groups to nothing', () {
    expect(groupRowsByStage(const []), isEmpty);
  });

  testWidgets('the header draws the stage name uppercase with its count', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RelayTheme.light,
        home: const Scaffold(
          body: StageGroupHeader(name: 'Code', type: 'work', count: 3),
        ),
      ),
    );

    expect(find.byKey(const Key('stage_group_Code')), findsOneWidget);
    expect(find.text('CODE'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('the header dot takes the stage type colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RelayTheme.light,
        home: const Scaffold(
          body: Column(
            children: [
              StageGroupHeader(name: 'Code', type: 'work', count: 1),
              StageGroupHeader(name: 'Spec', type: 'planning', count: 1),
            ],
          ),
        ),
      ),
    );

    Color dotColor(String name) {
      final box = tester.widget<Container>(
        find.byKey(Key('stage_group_dot_$name')),
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    expect(dotColor('Code'), RelayTheme.relayHuman); // work = Human blue
    expect(dotColor('Spec'), RelayTheme.relayAI); //   planning = AI violet
  });

  testWidgets('the unlabelled group renders as a neutral OTHER bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: RelayTheme.light,
        home: const Scaffold(
          body: StageGroupHeader(name: '', type: null, count: 2),
        ),
      ),
    );

    expect(find.byKey(const Key('stage_group_other')), findsOneWidget);
    expect(find.text('OTHER'), findsOneWidget);
    final box = tester.widget<Container>(
      find.byKey(const Key('stage_group_dot_other')),
    );
    expect(
      (box.decoration! as BoxDecoration).color,
      RelayTheme.relayStageNeutral,
    );
  });
}
