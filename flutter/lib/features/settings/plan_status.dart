// RE466: where a board owner's plan stands — the server's `billing` object on
// sign-in and `GET /api/auth/native/me` — and the status text Settings shows for
// it. Status only: the app sells nothing (App Store rules).

/// A plan's standing. The one client-side definition of the wire names, which
/// mirror the server's `Relay.Billing.Standing` kinds.
enum PlanStanding {
  trial('trial'),
  active('active'),
  pastDue('past_due'),
  cancelled('cancelled'),
  comped('comped'),
  paused('paused');

  const PlanStanding(this.wire);

  /// The name the server sends.
  final String wire;

  /// [s]'s standing, or null for null or a name this app doesn't know.
  static PlanStanding? fromWire(String? s) {
    for (final standing in values) {
      if (standing.wire == s) return standing;
    }
    return null;
  }
}

/// The parsed `billing` object: `{"enabled", "standing", "through"}`.
class PlanStatus {
  const PlanStatus({required this.enabled, this.standing, this.through});

  /// False when the operator runs Relay with billing switched off.
  final bool enabled;

  /// Null when the server sent none, or one this app doesn't know.
  final PlanStanding? standing;

  /// The trial's end, or the date paid (or cancelled) access runs through.
  /// Date-only, in no time zone, so "May 3" never renders as "May 2".
  final DateTime? through;

  /// The status in [json], or null when it isn't an object at all. A missing
  /// `billing` key (an older server) arrives here as null.
  static PlanStatus? fromJson(Object? json) {
    if (json is! Map) return null;
    final standing = json['standing'];
    return PlanStatus(
      enabled: json['enabled'] == true,
      standing: PlanStanding.fromWire(standing is String ? standing : null),
      through: _parseDate(json['through']),
    );
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// Whether Settings shows the ACCOUNT › Plan row at all.
  bool get visible => enabled && standing != null;

  /// The Plan row's text, e.g. `Active · through May 3`; null when not [visible].
  String? get label {
    if (!visible) return null;
    final date = through == null ? null : _monthDay(through!);
    return switch (standing!) {
      PlanStanding.trial => date == null ? 'Trial' : 'Trial · ends $date',
      PlanStanding.active => date == null ? 'Active' : 'Active · through $date',
      PlanStanding.pastDue => 'Past due',
      PlanStanding.cancelled =>
        date == null ? 'Cancelled' : 'Cancelled · through $date',
      PlanStanding.comped => 'Comped',
      PlanStanding.paused => 'Paused',
    };
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  /// `MMM d` — no leading zero, no year, and no `intl` dependency.
  static String _monthDay(DateTime d) => '${_months[d.month - 1]} ${d.day}';
}
