import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/decisions/answer_screen.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/decisions/review_queue.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/needs_you/models/feed_row.dart';
import 'package:relay_mobile/features/voice/voice_transcriber.dart';

import 'review_queue_test.dart'
    show BlockedDecisionApi, FakeDecisionApi, FakeFeedRepository, row;
import 'support/fake_voice_transcriber.dart';

final _submit = find.byKey(const Key('answer_submit'));
final _text = find.byKey(const Key('answer_text'));

FeedQuestion q(
  String prompt, {
  List<String> options = const ['us', 'eu'],
  bool allowText = true,
}) => FeedQuestion(prompt: prompt, options: options, allowText: allowText);

FilledButton _submitButton(WidgetTester tester) =>
    tester.widget<FilledButton>(_submit);

GoRouter _router({VoiceTranscriber? transcriber}) => GoRouter(
  initialLocation: '/card/RLY-A/answer',
  routes: [
    GoRoute(
      path: '/needs-you',
      builder: (c, s) =>
          const Scaffold(body: Text('inbox', key: Key('inbox_stub'))),
    ),
    GoRoute(
      path: '/card/:ref',
      builder: (c, s) => Scaffold(
        body: Text(
          'host ${s.pathParameters['ref']}',
          key: const Key('host_stub'),
        ),
      ),
    ),
    GoRoute(
      path: '/card/:ref/answer',
      builder: (c, s) => AnswerScreen(
        cardRef: s.pathParameters['ref']!,
        transcriber: transcriber,
      ),
    ),
  ],
);

Future<ProviderContainer> pumpAnswer(
  WidgetTester tester, {
  required DecisionApi api,
  required List<FeedRow> rows,
  FeedRepository? feed,
  VoiceTranscriber? transcriber,
}) async {
  final container = ProviderContainer(
    overrides: [
      decisionApiProvider.overrideWithValue(api),
      feedRepositoryProvider.overrideWithValue(feed ?? FakeFeedRepository()),
    ],
  );
  addTearDown(container.dispose);
  container
      .read(reviewQueueProvider.notifier)
      .enter(rows: rows, atRef: 'RLY-A');

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: RelayTheme.light,
        routerConfig: _router(transcriber: transcriber),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

List<FeedRow> _structured({
  bool allowText = true,
  List<String> options = const ['us', 'eu'],
}) => [
  row(
    'RLY-A',
    kind: 'needs_input',
    boardName: 'Data pipeline',
    stage: 'Prep',
    questions: [q('Which region?', options: options, allowText: allowText)],
  ),
  row('RLY-B', kind: 'needs_input', questions: [q('Ship it?')]),
];

void main() {
  testWidgets('a structured question renders the picker, not a text box', (
    tester,
  ) async {
    await pumpAnswer(tester, api: FakeDecisionApi(), rows: _structured());

    expect(find.text('Which region?'), findsOneWidget);
    expect(find.byKey(const Key('answer_option_0')), findsOneWidget);
    expect(find.byKey(const Key('answer_option_1')), findsOneWidget);
    expect(find.text('us'), findsOneWidget);
    expect(find.text('eu'), findsOneWidget);
    // INPUT-01's breadcrumb, straight off the snapshot — no second fetch (D7).
    expect(find.text('Data pipeline / Prep'), findsOneWidget);
    expect(find.text('PICK ONE · OR ADD YOUR OWN'), findsOneWidget);
    expect(find.text('NEEDS INPUT'), findsOneWidget);
    expect(_text, findsOneWidget); // the "Something else…" row
  });

  testWidgets(
    'a legacy string question renders a free-text field and no options',
    (tester) async {
      final api = FakeDecisionApi();
      await pumpAnswer(
        tester,
        api: api,
        // questions: null — the path bin/relay needs-input REF "…" and the runner's
        // [auto] flags take. A structured-only client would 400 here.
        rows: [
          row('RLY-A', kind: 'needs_input', reason: 'Which region?'),
          row('RLY-B', kind: 'needs_input', questions: [q('Ship it?')]),
        ],
      );

      expect(
        find.text('Which region?'),
        findsOneWidget,
      ); // the row's reason IS the question
      expect(_text, findsOneWidget);
      expect(find.byKey(const Key('answer_option_0')), findsNothing);
      expect(find.byKey(const Key('answer_step_counter')), findsNothing);
      expect(find.text('Send'), findsOneWidget);
      expect(
        _submitButton(tester).onPressed,
        isNull,
      ); // blank answer sends nothing

      await tester.enterText(_text, 'eu, please');
      await tester.pumpAndSettle();
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(api.answered.single.text, 'eu, please');
      expect(api.answered.single.answers, isNull);
    },
  );

  testWidgets('the answer field dictates and does not send', (tester) async {
    final api = FakeDecisionApi();
    final fake = FakeVoiceTranscriber(transcript: 'use the EU region');
    await pumpAnswer(
      tester,
      api: api,
      rows: [row('RLY-A', kind: 'needs_input', reason: 'Which region?')],
      transcriber: fake,
    );

    await tester.tap(find.byKey(const Key('answer_mic')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const Key('voice_stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('voice_use')));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(_text);
    expect(field.controller!.text, 'use the EU region');
    expect(api.answered, isEmpty, reason: 'no answer sent yet');
    expect(
      _submitButton(tester).onPressed,
      isNotNull,
      reason: 'the dictated answer must enable Send',
    );
  });

  testWidgets(
    'allow_text false hides the free-text row and shortens the label',
    (tester) async {
      await pumpAnswer(
        tester,
        api: FakeDecisionApi(),
        rows: _structured(allowText: false),
      );

      expect(find.text('PICK ONE'), findsOneWidget);
      expect(_text, findsNothing);
      expect(find.text('Type your own answer'), findsNothing);
    },
  );

  testWidgets(
    'an option-less step with allow_text renders prompt and text row only',
    (tester) async {
      await pumpAnswer(
        tester,
        api: FakeDecisionApi(),
        rows: _structured(options: const []),
      );

      expect(find.text('Which region?'), findsOneWidget);
      expect(_text, findsOneWidget);
      expect(find.byKey(const Key('answer_option_0')), findsNothing);
      expect(find.byKey(const Key('answer_section_label')), findsNothing);
      // Nothing to be "something else" than.
      expect(find.text('Something else…'), findsNothing);
    },
  );

  testWidgets(
    'the free-text row carries the live mic (RLY-99) and says "Type your own answer"',
    (tester) async {
      await pumpAnswer(tester, api: FakeDecisionApi(), rows: _structured());

      // D5 deferred INPUT-01's own mic; RLY-99 (U5) adds the shared MicButton here
      // instead, so this is the retrofit's component, not the artboard's drawn one.
      expect(find.text('Type your own answer'), findsOneWidget);
      expect(find.byKey(const Key('answer_mic')), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
    },
  );

  testWidgets('Send is disabled until the current question is answered', (
    tester,
  ) async {
    final api = FakeDecisionApi();
    await pumpAnswer(tester, api: api, rows: _structured());

    expect(_submitButton(tester).onPressed, isNull);

    await tester.tap(_submit);
    await tester.pumpAndSettle();
    expect(api.answered, isEmpty); // tapping a disabled button posts nothing

    await tester.tap(find.byKey(const Key('answer_option_1')));
    await tester.pumpAndSettle();
    expect(_submitButton(tester).onPressed, isNotNull);
  });

  testWidgets(
    'a selected option paints INPUT-01 blue and a second pick moves it',
    (tester) async {
      await pumpAnswer(tester, api: FakeDecisionApi(), rows: _structured());

      BoxDecoration decorationOf(String key) =>
          tester.widget<Container>(find.byKey(Key(key))).decoration!
              as BoxDecoration;

      await tester.tap(find.byKey(const Key('answer_option_0')));
      await tester.pumpAndSettle();
      expect(
        decorationOf('answer_option_0').color,
        const Color(0xFFE3F4FF),
      ); // oklch(0.96 0.03 250)
      expect(decorationOf('answer_option_1').color, Colors.white);

      // Single-select: picking the other one clears the first.
      await tester.tap(find.byKey(const Key('answer_option_1')));
      await tester.pumpAndSettle();
      expect(decorationOf('answer_option_0').color, Colors.white);
      expect(decorationOf('answer_option_1').color, const Color(0xFFE3F4FF));
    },
  );

  testWidgets(
    'a multi-question round steps Next → Send and answers positionally',
    (tester) async {
      final api = FakeDecisionApi();
      await pumpAnswer(
        tester,
        api: api,
        rows: [
          row(
            'RLY-A',
            kind: 'needs_input',
            questions: [
              q('Which region?', options: const ['us', 'eu'], allowText: false),
              q('Ship it?', options: const ['yes', 'no'], allowText: false),
            ],
          ),
          row('RLY-B', kind: 'needs_input', questions: [q('Ship it?')]),
        ],
      );

      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);

      await tester.tap(find.byKey(const Key('answer_option_1'))); // eu
      await tester.pump();
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(find.text('2 of 2'), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      await tester.tap(find.byKey(const Key('answer_option_1'))); // no
      await tester.pump();
      await tester.tap(_submit);
      await tester.pumpAndSettle();

      expect(api.answered.single.answers, [
        {'value': 'eu'},
        {'value': 'no'},
      ]);
    },
  );

  testWidgets('sending auto-advances to the next item and banners it there', (
    tester,
  ) async {
    await pumpAnswer(tester, api: FakeDecisionApi(), rows: _structured());

    await tester.tap(find.byKey(const Key('answer_option_1')));
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    // INPUT-02 is superseded (D4): no confirmation screen, straight to the next item.
    expect(find.text('Ship it?'), findsOneWidget);
    expect(find.text('Answer sent · RLY-A'), findsOneWidget);
  });

  testWidgets('answering the last item lands on the inbox', (tester) async {
    await pumpAnswer(
      tester,
      api: FakeDecisionApi(),
      rows: [
        row('RLY-A', kind: 'needs_input', questions: [q('Which region?')]),
      ],
    );

    await tester.tap(find.byKey(const Key('answer_option_0')));
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox_stub')), findsOneWidget);
  });

  testWidgets('a card already handled on the web skips with a banner', (
    tester,
  ) async {
    await pumpAnswer(
      tester,
      api: FakeDecisionApi(
        const DecisionFailed(
          'not_needs_input',
          'This card is not waiting on an answer',
        ),
      ),
      rows: _structured(),
    );

    await tester.tap(find.byKey(const Key('answer_option_1')));
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.text('Already handled · RLY-A'), findsOneWidget);
    expect(find.text('Ship it?'), findsOneWidget);
  });

  testWidgets('a failure stays put, surfaces the message, and keeps the pick', (
    tester,
  ) async {
    await pumpAnswer(
      tester,
      api: FakeDecisionApi(
        const DecisionFailed(
          'network',
          'Network error — could not reach Relay.',
        ),
      ),
      rows: _structured(),
    );

    await tester.tap(find.byKey(const Key('answer_option_1')));
    await tester.pump();
    await tester.tap(_submit);
    await tester.pumpAndSettle();

    expect(find.text('Network error — could not reach Relay.'), findsOneWidget);
    expect(find.text('Which region?'), findsOneWidget); // did not advance
    // Never silently discard an answer: the pick survives for the retry.
    final decoration =
        tester
                .widget<Container>(find.byKey(const Key('answer_option_1')))
                .decoration!
            as BoxDecoration;
    expect(decoration.color, const Color(0xFFE3F4FF));
    expect(find.byKey(const Key('answer_retry')), findsOneWidget);
  });

  testWidgets('a second tap during an in-flight POST issues no second POST', (
    tester,
  ) async {
    final api = BlockedDecisionApi();
    await pumpAnswer(tester, api: api, rows: _structured());

    await tester.tap(find.byKey(const Key('answer_option_1')));
    await tester.pumpAndSettle();

    await tester.tap(_submit);
    await tester.pump(); // in flight, not settled
    await tester.tap(_submit);
    await tester.pump();

    expect(api.calls, 1);
    api.completer.complete(const DecisionOk({}));
    await tester.pumpAndSettle();
  });

  testWidgets(
    "a card that is not the queue's current item says so rather than dead-ending",
    (tester) async {
      await pumpAnswer(
        tester,
        api: FakeDecisionApi(),
        rows: [
          row('RLY-Z', kind: 'needs_input', questions: [q('Which region?')]),
        ],
      );

      // enter(atRef: 'RLY-A') found no such row, so the queue sits on RLY-Z while the
      // route asks for RLY-A. Render the way back, not a dead button.
      expect(find.byKey(const Key('answer_unavailable')), findsOneWidget);
      expect(_submit, findsNothing);
    },
  );
}
