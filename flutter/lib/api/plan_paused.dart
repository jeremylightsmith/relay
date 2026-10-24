/// RE466 — the client half of the `plan_paused` refusal.
///
/// A board whose owner's plan is paused answers the native writes (approve,
/// reject, create card) with **402** `{"error": {"code": "plan_paused", ...}}`
/// (`RelayWeb.PlanPaused`, whose `code/0` this pins — see
/// `test/plan_paused_test.dart`). This file is the one Dart definition of that
/// code and of the copy the decision surfaces show inline in its place.
library;

/// `RelayWeb.PlanPaused.code/0`.
const String planPausedCode = 'plan_paused';

/// What the human reads. Deliberately not the server's `message`: on a phone
/// the useful fact is that the board is read-only, and why.
const String planPausedMessage =
    "This board is read-only because its owner's plan is paused.";
