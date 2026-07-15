import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/decisions/decision_api.dart';
import 'package:relay_mobile/features/decisions/reject_note_screen.dart';
import 'package:relay_mobile/features/decisions/review_queue.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';

import 'review_queue_test.dart' show FakeDecisionApi, FakeFeedRepository, row;

final _input = find.byKey(const Key('reject_note_input'));
final _send = find.byKey(const Key('reject_send'));

FilledButton _sendButton(WidgetTester tester) =>
    tester.widget<FilledButton>(_send);

GoRouter _router() => GoRouter(
  initialLocation: '/card/RLY-A',
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
          'card ${s.pathParameters['ref']}',
          key: const Key('card_stub'),
        ),
      ),
    ),
    GoRoute(
      path: '/card/:ref/reject',
      builder: (c, s) => RejectNoteScreen(
        cardRef: s.pathParameters['ref']!,
        boardSlug: s.uri.queryParameters['board'] ?? '',
      ),
    ),
  ],
);

Future<GoRouter> pumpReject(
  WidgetTester tester, {
  required DecisionApi api,
  FeedRepository? feed,
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
      .enter(rows: [row('RLY-A'), row('RLY-B')], atRef: 'RLY-A');

  final router = _router();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(theme: RelayTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  router.push('/card/RLY-A/reject?board=relay');
  await tester.pumpAndSettle();
  return router;
}

void main() {
  group('CORE-07 fidelity', () {
    testWidgets('the nav title reads "Send back", not "Reject"', (
      tester,
    ) async {
      await pumpReject(tester, api: FakeDecisionApi());

      expect(
        tester.widget<Text>(find.byKey(const Key('reject_nav_title'))).data,
        'Send back',
      );
      expect(find.text('Reject'), findsNothing);
    });

    testWidgets('the body copy bolds "required"', (tester) async {
      await pumpReject(tester, api: FakeDecisionApi());

      final copy = tester.widget<Text>(
        find.byKey(const Key('reject_body_copy')),
      );
      expect(
        copy.textSpan!.toPlainText(),
        'Tell Relay AI what to fix. A note is required so it can revise.',
      );
      final bolded = (copy.textSpan! as TextSpan).children!
          .cast<TextSpan>()
          .firstWhere((s) => s.text == 'required');
      expect(bolded.style!.fontWeight, FontWeight.w700);
    });

    testWidgets(
      'the note field carries the artboard border, radius and min-height',
      (tester) async {
        await pumpReject(tester, api: FakeDecisionApi());

        final field = tester.widget<Container>(
          find.byKey(const Key('reject_note_field')),
        );
        final deco = field.decoration! as BoxDecoration;
        expect(
          deco.border,
          Border.all(color: RelayTheme.relayRejectBorder, width: 1.5),
        );
        expect(deco.borderRadius, BorderRadius.circular(12));
        expect(field.constraints!.minHeight, 120);
      },
    );

    testWidgets('the placeholder reads "Reason…"', (tester) async {
      await pumpReject(tester, api: FakeDecisionApi());

      final input = tester.widget<TextField>(_input);
      expect(input.decoration!.hintText, 'Reason…');
      expect(
        input.maxLines,
        isNull,
        reason: 'the artboard field is multi-line',
      );
    });

    testWidgets('the hint drops the "or dictate it" half (D4a)', (
      tester,
    ) async {
      await pumpReject(tester, api: FakeDecisionApi());

      expect(find.text('Add a reason to continue'), findsOneWidget);
      expect(find.textContaining('dictate'), findsNothing);
    });

    testWidgets('the mic is drawn to the artboard geometry but ghosted', (
      tester,
    ) async {
      await pumpReject(tester, api: FakeDecisionApi());

      final mic = tester.widget<Container>(find.byKey(const Key('reject_mic')));
      expect(mic.constraints, BoxConstraints.tight(const Size(30, 30)));
      final deco = mic.decoration! as BoxDecoration;
      expect(deco.shape, BoxShape.circle);
      expect(deco.color, RelayTheme.micGhostFill);
      expect(deco.border, Border.all(color: RelayTheme.micGhostBorder));
    });

    testWidgets(
      'the mic is inert: no tap handler, and no screen-reader button',
      (tester) async {
        final api = FakeDecisionApi();
        await pumpReject(tester, api: api);

        await tester.tap(find.byKey(const Key('reject_mic')));
        await tester.pumpAndSettle();

        expect(api.rejected, isEmpty);
        expect(
          find.byType(SnackBar),
          findsNothing,
          reason: 'no "coming soon" toast',
        );
        expect(_send, findsOneWidget, reason: 'still on the reject screen');
        // A dead control must not be announced as a live one.
        expect(
          find.ancestor(
            of: find.byKey(const Key('reject_mic')),
            matching: find.byType(ExcludeSemantics),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('the disabled button wears the artboard disabled treatment', (
      tester,
    ) async {
      await pumpReject(tester, api: FakeDecisionApi());

      final style = _sendButton(tester).style!;
      expect(
        style.backgroundColor!.resolve({WidgetState.disabled}),
        RelayTheme.relayRejectDisabledBg,
      );
      expect(
        style.foregroundColor!.resolve({WidgetState.disabled}),
        RelayTheme.relayRejectDisabledFg,
      );
      expect(style.backgroundColor!.resolve({}), RelayTheme.relayReject);
    });
  });

  testWidgets('Send back is disabled while the note is blank or whitespace', (
    tester,
  ) async {
    await pumpReject(tester, api: FakeDecisionApi());

    expect(_sendButton(tester).onPressed, isNull, reason: 'empty');

    await tester.enterText(_input, '   ');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNull, reason: 'whitespace-only');

    await tester.enterText(_input, 'Needs error handling');
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('sending posts the note and auto-advances to the next item', (
    tester,
  ) async {
    final api = FakeDecisionApi();
    await pumpReject(tester, api: api);

    await tester.enterText(_input, 'Needs error handling');
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();

    expect(api.rejected, ['RLY-A']);
    expect(find.text('card RLY-B'), findsOneWidget);
    expect(_send, findsNothing, reason: 'the reject screen is gone');
    expect(
      find.text('card RLY-A'),
      findsNothing,
      reason: 'RLY-A was replaced, not stacked under RLY-B',
    );
  });

  testWidgets('a failure keeps the typed note and shows the server message', (
    tester,
  ) async {
    final api = FakeDecisionApi(
      const DecisionFailed('network', 'Network error — could not reach Relay.'),
    );
    await pumpReject(tester, api: api);

    await tester.enterText(_input, 'Please revise');
    await tester.pump();
    await tester.tap(_send);
    await tester.pumpAndSettle();

    // Never silently discard a typed note.
    expect(find.text('Please revise'), findsOneWidget);
    expect(find.text('Network error — could not reach Relay.'), findsOneWidget);
    expect(find.text('card RLY-B'), findsNothing, reason: 'must not advance');
    expect(_sendButton(tester).onPressed, isNotNull, reason: 'retryable');
  });
}
