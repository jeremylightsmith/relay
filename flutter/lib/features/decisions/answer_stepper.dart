import '../needs_you/models/feed_row.dart';

/// The needs-input stepper's state: which question we are on, and the one answer
/// slot per question. Pure — no I/O, no widgets, no Flutter.
///
/// A deliberate port of the web stepper (`board_live.ex` `answer_select` /
/// `answer_custom` / `answer_next` / `answer_back`, and `core_components.ex`
/// `stepper_custom_text/3`), so the two surfaces answer a question identically.
/// `answer_goto` is **not** ported: it is the only way the web can leave a gap, and
/// without it every step is answered before Send.
class AnswerStepper {
  AnswerStepper(this.questions)
    : assert(questions.isNotEmpty, 'a stepper needs at least one question');

  final List<FeedQuestion> questions;

  /// One slot per step. An option pick and typed text share it — last write wins.
  final Map<int, String> _values = {};

  int _step = 0;

  int get step => _step;
  int get length => questions.length;
  FeedQuestion get current => questions[_step];
  bool get isLast => _step == questions.length - 1;

  /// The current step's answer, however it was given.
  String? get value => _values[_step];

  /// Next/Send stay disabled until the current step has a value — mirrors the web's
  /// `disabled={not Map.has_key?(@answer_values, @answer_step)}`.
  bool get canAdvance => _values.containsKey(_step);

  /// What the free-text row shows: the slot's value, but only when it was *typed*.
  /// Picking an option must clear the text row rather than echo the option into it
  /// (`stepper_custom_text/3`).
  String get customText {
    final current = _values[_step];
    if (current == null || questions[_step].options.contains(current)) {
      return '';
    }
    return current;
  }

  /// Single-select: one slot per step, so a second pick replaces the first.
  void select(String option) => _values[_step] = option;

  /// Blank text deletes the slot, so Next/Send re-disable.
  void setText(String text) {
    if (text.trim().isEmpty) {
      _values.remove(_step);
    } else {
      _values[_step] = text;
    }
  }

  void next() {
    if (_step < questions.length - 1) _step++;
  }

  void back() {
    if (_step > 0) _step--;
  }

  /// The `answers[]` POST body — **positional**: entry *i* answers question *i*.
  ///
  /// LOAD-BEARING. `AllController.compose/2` zips this against
  /// `Cards.latest_questions/1` **by index**; there is no id or prompt on the wire,
  /// and `answer_value/1` falls through to `""` for anything malformed. A list that
  /// reorders, filters or drops an entry therefore **mis-attributes answers silently
  /// instead of erroring**. Always exactly `questions.length` entries, in order — an
  /// unanswered step composes `""`, exactly as `compose_answer/2` does for a missing
  /// index.
  List<Map<String, String>> toAnswers() => [
    for (var i = 0; i < questions.length; i++) {'value': _values[i] ?? ''},
  ];
}
