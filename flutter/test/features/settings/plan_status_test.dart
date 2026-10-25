// RE466: the parsed `billing` object the server puts on sign-in and /me, and
// the status text Settings' ACCOUNT › Plan row shows for it.
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/settings/plan_status.dart';

String? labelOf(Object? json) => PlanStatus.fromJson(json)!.label;

void main() {
  test('free is just "Free", with no date', () {
    expect(
      labelOf({'enabled': true, 'standing': 'free', 'through': null}),
      'Free',
    );
  });

  test('free ignores a through date if one is sent', () {
    expect(
      labelOf({'enabled': true, 'standing': 'free', 'through': '2026-04-03'}),
      'Free',
    );
  });

  test('an older server\'s trial standing is unknown and invisible', () {
    final status = PlanStatus.fromJson({
      'enabled': true,
      'standing': 'trial',
      'through': '2026-04-03',
    })!;
    expect(status.standing, isNull);
    expect(status.visible, isFalse);
    expect(status.label, isNull);
  });

  test('active with a through date runs through it', () {
    expect(
      labelOf({'enabled': true, 'standing': 'active', 'through': '2026-05-03'}),
      'Active · through May 3',
    );
  });

  test('past due shows no date even when one is sent', () {
    expect(
      labelOf({
        'enabled': true,
        'standing': 'past_due',
        'through': '2026-05-03',
      }),
      'Past due',
    );
  });

  test('cancelled runs through its date, or stands alone without one', () {
    expect(
      labelOf({
        'enabled': true,
        'standing': 'cancelled',
        'through': '2026-05-03',
      }),
      'Cancelled · through May 3',
    );
    expect(
      labelOf({'enabled': true, 'standing': 'cancelled', 'through': null}),
      'Cancelled',
    );
  });

  test('comped and paused are bare words', () {
    expect(
      labelOf({'enabled': true, 'standing': 'comped', 'through': null}),
      'Comped',
    );
    expect(
      labelOf({'enabled': true, 'standing': 'paused', 'through': null}),
      'Paused',
    );
  });

  test('active with no through date is just "Active"', () {
    expect(labelOf({'enabled': true, 'standing': 'active'}), 'Active');
  });

  test('billing switched off is invisible and has no label', () {
    final status = PlanStatus.fromJson({
      'enabled': false,
      'standing': null,
      'through': null,
    })!;
    expect(status.visible, isFalse);
    expect(status.label, isNull);
  });

  test('an unknown standing parses to null and is invisible', () {
    final status = PlanStatus.fromJson({'enabled': true, 'standing': 'gold'})!;
    expect(status.standing, isNull);
    expect(status.visible, isFalse);
    expect(status.label, isNull);
  });

  test('a non-Map payload is no status at all', () {
    expect(PlanStatus.fromJson(null), isNull);
    expect(PlanStatus.fromJson('active'), isNull);
  });

  test('a malformed through parses to null instead of throwing', () {
    final status = PlanStatus.fromJson({
      'enabled': true,
      'standing': 'active',
      'through': 'soon',
    })!;
    expect(status.through, isNull);
    expect(status.label, 'Active');
  });

  test('the date has no leading zero and no year', () {
    expect(
      labelOf({'enabled': true, 'standing': 'active', 'through': '2026-12-09'}),
      'Active · through Dec 9',
    );
  });

  test('fromWire maps every wire name, and nothing else', () {
    expect(PlanStanding.fromWire('free'), PlanStanding.free);
    expect(PlanStanding.fromWire('active'), PlanStanding.active);
    expect(PlanStanding.fromWire('past_due'), PlanStanding.pastDue);
    expect(PlanStanding.fromWire('cancelled'), PlanStanding.cancelled);
    expect(PlanStanding.fromWire('comped'), PlanStanding.comped);
    expect(PlanStanding.fromWire('paused'), PlanStanding.paused);
    expect(PlanStanding.fromWire('trial'), isNull);
    expect(PlanStanding.fromWire('pastDue'), isNull);
    expect(PlanStanding.fromWire(null), isNull);
  });
}
