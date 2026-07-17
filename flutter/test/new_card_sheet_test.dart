import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/features/board/board_api.dart';
import 'package:relay_mobile/features/board/new_card_sheet.dart';

const request = CreateCardRequest(
  board: 'relay',
  stages: ['Backlog', 'Spec', 'Code', 'Done'],
  current: 'Spec',
);

/// Pumps a host page whose button opens the real modal sheet, so pop-on-success
/// is observable.
Future<void> pumpHost(
  WidgetTester tester, {
  CreateCardRequest req = request,
  SubmitCreateCard? submit,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNewCardSheet(context, req, submit: submit),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('CreateCardRequest.fromPayload', () {
    test('parses board, stages, and current', () {
      final req = CreateCardRequest.fromPayload({
        'board': 'relay',
        'stages': ['Backlog', 'Spec'],
        'current': 'Spec',
      });

      expect(req!.board, 'relay');
      expect(req.stages, ['Backlog', 'Spec']);
      expect(req.current, 'Spec');
    });

    test('is null without a board or stages — nothing to create into', () {
      expect(CreateCardRequest.fromPayload(const {}), isNull);
      expect(
        CreateCardRequest.fromPayload({
          'stages': ['Backlog'],
        }),
        isNull,
      );
      expect(
        CreateCardRequest.fromPayload({'board': 'relay', 'stages': const []}),
        isNull,
      );
    });

    test('a current missing from stages falls back to the first stage', () {
      final req = CreateCardRequest.fromPayload({
        'board': 'relay',
        'stages': ['Backlog', 'Spec'],
        'current': 'Gone',
      });

      expect(req!.current, 'Backlog');
    });
  });

  testWidgets('renders BOARD-04: title, description + mic, chips, Add card', (
    tester,
  ) async {
    await pumpHost(tester);

    expect(find.text('New card'), findsOneWidget);
    expect(find.byKey(const Key('new_card_title')), findsOneWidget);
    expect(
      find.text('Add a description, or tap the mic to dictate…'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Dictate'), findsOneWidget);
    for (final stage in request.stages) {
      expect(find.byKey(Key('stage_chip_$stage')), findsOneWidget);
    }
    expect(find.byKey(const Key('new_card_submit')), findsOneWidget);

    // The title field is autofocused for immediate typing (BOARD-04's focused frame).
    final titleField = tester.widget<TextField>(
      find.byKey(const Key('new_card_title')),
    );
    expect(titleField.autofocus, isTrue);
  });

  testWidgets('Add card stays disabled until the title is non-blank', (
    tester,
  ) async {
    await pumpHost(tester);

    FilledButton submit() =>
        tester.widget<FilledButton>(find.byKey(const Key('new_card_submit')));

    expect(submit().onPressed, isNull);

    await tester.enterText(find.byKey(const Key('new_card_title')), '   ');
    await tester.pump();
    expect(submit().onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('new_card_title')),
      'Fix the footer',
    );
    await tester.pump();
    expect(submit().onPressed, isNotNull);
  });

  testWidgets('submits the PICKED stage (not the default) and pops on 201', (
    tester,
  ) async {
    final calls = <Map<String, String?>>[];
    Future<CreateCardResult> fake({
      required String board,
      required String stage,
      required String title,
      String? description,
    }) async {
      calls.add({
        'board': board,
        'stage': stage,
        'title': title,
        'description': description,
      });
      return const CreateCardOk({
        'data': {'ref': 'RLY-9'},
      });
    }

    await pumpHost(tester, submit: fake);

    await tester.enterText(
      find.byKey(const Key('new_card_title')),
      'Fix the footer',
    );
    await tester.enterText(
      find.byKey(const Key('new_card_description')),
      'the details',
    );
    await tester.tap(find.byKey(const Key('stage_chip_Code')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('new_card_submit')));
    await tester.pumpAndSettle();

    expect(calls.single, {
      'board': 'relay',
      'stage': 'Code',
      'title': 'Fix the footer',
      'description': 'the details',
    });
    // The sheet closed — the board (with its LiveView realtime) shows the card.
    expect(find.byKey(const Key('new_card_title')), findsNothing);
  });

  testWidgets('the pre-selected chip is the pager\'s current stage', (
    tester,
  ) async {
    final calls = <Map<String, String?>>[];
    Future<CreateCardResult> fake({
      required String board,
      required String stage,
      required String title,
      String? description,
    }) async {
      calls.add({'stage': stage});
      return const CreateCardOk({
        'data': {'ref': 'RLY-9'},
      });
    }

    await pumpHost(tester, submit: fake);

    await tester.enterText(find.byKey(const Key('new_card_title')), 'x');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new_card_submit')));
    await tester.pumpAndSettle();

    expect(calls.single['stage'], 'Spec');
  });

  testWidgets('a failed submit keeps the sheet open with an inline error', (
    tester,
  ) async {
    Future<CreateCardResult> fake({
      required String board,
      required String stage,
      required String title,
      String? description,
    }) async => const CreateCardFailed('invalid_stage', 'server says no');

    await pumpHost(tester, submit: fake);

    await tester.enterText(find.byKey(const Key('new_card_title')), 'x');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new_card_submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new_card_title')), findsOneWidget);
    expect(find.text('server says no'), findsOneWidget);
  });
}
