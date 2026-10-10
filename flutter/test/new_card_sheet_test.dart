import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/board/board_api.dart';
import 'package:relay_mobile/features/board/new_card_sheet.dart';

const request = CreateCardRequest(
  board: 'relay',
  stages: ['Backlog', 'Spec', 'Code', 'Done'],
  current: 'Spec',
);

/// Ten stages — enough chips that, under a long description, some start
/// below the keyboard.
const manyStages = CreateCardRequest(
  board: 'relay',
  stages: [
    'Backlog',
    'Ready for Design',
    'Design',
    'Ready for Spec',
    'Spec',
    'Ready to Code',
    'Code',
    'Review',
    'Deploy',
    'Done',
  ],
  current: 'Backlog',
);

/// 7,999 chars — long enough to overflow any phone sheet.
final longText = List.filled(800, 'dictation').join(' ');

final _header = find.byKey(const Key('sheet_header'));
final _body = find.byKey(const Key('sheet_body'));
final _submitKey = find.byKey(const Key('new_card_submit'));

/// The body's own Scrollable — `.first` because each TextField inside it
/// carries a Scrollable of its own further down the tree.
final _bodyScrollable = find
    .descendant(of: _body, matching: find.byType(Scrollable))
    .first;

/// The key sits on the SheetHeaderAction wrapper; this reads its button.
FilledButton _submitButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.descendant(of: _submitKey, matching: find.byType(FilledButton)),
);

/// A 390×844 phone (status bar 47, home indicator 34) with a 300px keyboard
/// up: the visible area is y ∈ [47, 544].
void _phoneWithKeyboard(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  addTearDown(tester.view.reset);
}

/// A submit fake that records each call's payload and returns 201.
SubmitCreateCard _recording(List<Map<String, String?>> calls) =>
    ({
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
    };

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

  testWidgets('header: Cancel | New card | Add; the form sits in the body', (
    tester,
  ) async {
    await pumpHost(tester);

    final cancel = find.byKey(const Key('new_card_cancel'));
    final title = find.text('New card');
    for (final f in [cancel, title, _submitKey]) {
      expect(find.descendant(of: _header, matching: f), findsOneWidget);
    }
    expect(tester.getCenter(cancel).dx, lessThan(tester.getCenter(title).dx));
    expect(
      tester.getCenter(title).dx,
      lessThan(tester.getCenter(_submitKey).dx),
    );
    expect(
      find.descendant(of: _submitKey, matching: find.text('Add')),
      findsOneWidget,
    );
    expect(find.text('Add card'), findsNothing);

    final titleStyle = tester.widget<Text>(title).style!;
    expect(titleStyle.fontSize, 16);
    expect(titleStyle.fontWeight, FontWeight.w600);
    expect(titleStyle.letterSpacing, -0.3);

    for (final f in [
      find.byKey(const Key('new_card_title')),
      find.text('Add a description, or tap the mic to dictate…'),
      find.bySemanticsLabel('Dictate'),
      for (final stage in request.stages) find.byKey(Key('stage_chip_$stage')),
    ]) {
      expect(find.descendant(of: _body, matching: f), findsOneWidget);
    }

    // The title field is autofocused for immediate typing (BOARD-04's focused frame).
    final titleField = tester.widget<TextField>(
      find.byKey(const Key('new_card_title')),
    );
    expect(titleField.autofocus, isTrue);

    final description = tester.widget<TextField>(
      find.byKey(const Key('new_card_description')),
    );
    expect(description.minLines, 2);
    expect(description.maxLines, isNull);
  });

  testWidgets('Add stays disabled until the title is non-blank', (
    tester,
  ) async {
    await pumpHost(tester);

    expect(_submitButton(tester).onPressed, isNull);

    await tester.enterText(find.byKey(const Key('new_card_title')), '   ');
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('new_card_title')),
      'Fix the footer',
    );
    await tester.pump();
    expect(_submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('Add shows a spinner while submitting, then the sheet closes', (
    tester,
  ) async {
    final pending = Completer<CreateCardResult>();
    Future<CreateCardResult> fake({
      required String board,
      required String stage,
      required String title,
      String? description,
    }) => pending.future;

    await pumpHost(tester, submit: fake);
    await tester.enterText(find.byKey(const Key('new_card_title')), 'x');
    await tester.pump();
    await tester.tap(_submitKey);
    await tester.pump();

    expect(
      find.descendant(
        of: _submitKey,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('Add'), findsNothing);
    expect(_submitButton(tester).onPressed, isNull);

    pending.complete(
      const CreateCardOk({
        'data': {'ref': 'RLY-9'},
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('new_card_title')), findsNothing);
  });

  testWidgets('a long description with the keyboard up never hides Add', (
    tester,
  ) async {
    _phoneWithKeyboard(tester);
    final calls = <Map<String, String?>>[];
    await pumpHost(tester, submit: _recording(calls));

    await tester.enterText(
      find.byKey(const Key('new_card_title')),
      'Scrolling is bad on mobile',
    );
    await tester.enterText(
      find.byKey(const Key('new_card_description')),
      longText,
    );
    await tester.pump();

    expect(_submitKey.hitTestable(), findsOneWidget);
    final rect = tester.getRect(_submitKey);
    expect(rect.top, greaterThanOrEqualTo(47));
    expect(rect.bottom, lessThanOrEqualTo(544));

    await tester.tap(_submitKey);
    await tester.pumpAndSettle();

    expect(calls, [
      {
        'board': 'relay',
        'stage': 'Spec',
        'title': 'Scrolling is bad on mobile',
        'description': longText,
      },
    ]);
    expect(find.byKey(const Key('new_card_title')), findsNothing);
  });

  testWidgets('the form scrolls to reach an off-screen stage chip', (
    tester,
  ) async {
    _phoneWithKeyboard(tester);
    final calls = <Map<String, String?>>[];
    await pumpHost(tester, req: manyStages, submit: _recording(calls));

    await tester.enterText(find.byKey(const Key('new_card_title')), 'x');
    await tester.enterText(
      find.byKey(const Key('new_card_description')),
      longText,
    );
    await tester.pumpAndSettle();

    final deploy = find.byKey(const Key('stage_chip_Deploy'));
    expect(deploy.hitTestable(), findsNothing);

    await tester.scrollUntilVisible(deploy, 200, scrollable: _bodyScrollable);
    await tester.tap(deploy);
    await tester.pump();

    final chip = tester.widget<Container>(
      find.descendant(of: deploy, matching: find.byType(Container)).first,
    );
    expect(
      (chip.decoration! as BoxDecoration).color,
      RelayTheme.relayChipSelectedBg,
    );

    expect(_submitKey.hitTestable(), findsOneWidget);
    final rect = tester.getRect(_submitKey);
    expect(rect.top, greaterThanOrEqualTo(47));
    expect(rect.bottom, lessThanOrEqualTo(544));

    await tester.tap(_submitKey);
    await tester.pumpAndSettle();
    expect(calls.single['stage'], 'Deploy');
  });

  testWidgets('the description grows with no 4-line cap', (tester) async {
    _phoneWithKeyboard(tester);
    await pumpHost(tester);

    await tester.enterText(
      find.byKey(const Key('new_card_description')),
      longText,
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('new_card_description'))).height,
      greaterThan(544 - 47),
    );
  });

  testWidgets('the body scrolls to keep the caret visible while typing', (
    tester,
  ) async {
    _phoneWithKeyboard(tester);
    await pumpHost(tester);

    await tester.enterText(
      find.byKey(const Key('new_card_description')),
      longText,
    );
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(_bodyScrollable);
    expect(scrollable.position.pixels, greaterThan(0));
  });

  testWidgets('Cancel closes the sheet without submitting', (tester) async {
    final calls = <Map<String, String?>>[];
    await pumpHost(tester, submit: _recording(calls));

    await tester.enterText(find.byKey(const Key('new_card_title')), 'x');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new_card_cancel')));
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(find.byKey(const Key('new_card_title')), findsNothing);
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
    expect(
      find.descendant(of: _body, matching: find.text('server says no')),
      findsOneWidget,
    );
  });
}
