import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/features/card/widgets/card_review_bar.dart';

/// A body tall enough to scroll — the bar must survive it (brief §04: "you never
/// lose the approve/reject bar").
Widget tallBody(BuildContext context) => ListView(
  key: const Key('stub_card_body'),
  children: List.generate(
    40,
    (i) => SizedBox(height: 60, child: Text('line $i')),
  ),
);

Future<void> pumpCard(WidgetTester tester, {String? kind}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: CardScreen(
        cardRef: 'RLY-42',
        boardSlug: 'marketing',
        kind: kind,
        bodyBuilder: tallBody,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the bar swaps by card kind', () {
    testWidgets('in_review shows the approve/reject bar', (tester) async {
      await pumpCard(tester, kind: 'in_review');

      expect(find.byType(CardReviewBar), findsOneWidget);
      expect(find.byKey(const Key('card_approve')), findsOneWidget);
      expect(find.byKey(const Key('card_reject')), findsOneWidget);
    });

    testWidgets('needs_input shows no bar — RLY-89 fills this slot', (
      tester,
    ) async {
      await pumpCard(tester, kind: 'needs_input');

      expect(find.byType(CardReviewBar), findsNothing);
      expect(find.byKey(const Key('card_approve')), findsNothing);
      // The body still renders: the web stepper inside it is how V1-7 answers.
      expect(find.byKey(const Key('stub_card_body')), findsOneWidget);
    });

    testWidgets('an absent or unknown kind shows no bar, never a guess', (
      tester,
    ) async {
      for (final kind in [null, '', 'something_else']) {
        await pumpCard(tester, kind: kind);
        expect(find.byType(CardReviewBar), findsNothing);
      }
    });
  });

  group('the bar is persistent', () {
    testWidgets('it survives scrolling the card body', (tester) async {
      await pumpCard(tester, kind: 'in_review');
      expect(find.byKey(const Key('card_approve')), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('stub_card_body')),
        const Offset(0, -1200),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('card_approve')), findsOneWidget);
      expect(find.byKey(const Key('card_reject')), findsOneWidget);
    });
  });

  group(
    'the bar matches CORE-03 (docs/designs/Relay Mobile.dc.html line 188)',
    () {
      testWidgets(
        'Approve is filled primary; Reject is outlined with the danger tint',
        (tester) async {
          await pumpCard(tester, kind: 'in_review');

          final approve = tester.widget<FilledButton>(
            find.byKey(const Key('card_approve')),
          );
          final reject = tester.widget<OutlinedButton>(
            find.byKey(const Key('card_reject')),
          );

          // Approve: oklch(0.60 0.14 250) == relayHumanLight == colorScheme.primary.
          expect(
            approve.style!.backgroundColor!.resolve({}),
            RelayTheme.relayHumanLight,
          );
          expect(approve.style!.foregroundColor!.resolve({}), Colors.white);

          // Reject: white fill, red-tinted border and label.
          expect(
            reject.style!.backgroundColor!.resolve({}),
            RelayTheme.light.colorScheme.surface,
          );
          expect(
            reject.style!.side!.resolve({})!.color,
            RelayTheme.relayRejectBorder,
          );
          expect(
            reject.style!.foregroundColor!.resolve({}),
            RelayTheme.relayRejectLabel,
          );
        },
      );

      testWidgets('Approve is wider than Reject (flex 1.4 : 1)', (
        tester,
      ) async {
        await pumpCard(tester, kind: 'in_review');

        int flexOf(Key key) => tester
            .widget<Expanded>(
              find
                  .ancestor(
                    of: find.byKey(key),
                    matching: find.byType(Expanded),
                  )
                  .first,
            )
            .flex;

        expect(
          flexOf(const Key('card_approve')) / flexOf(const Key('card_reject')),
          1.4,
        );
        expect(
          tester.getSize(find.byKey(const Key('card_approve'))).width,
          greaterThan(
            tester.getSize(find.byKey(const Key('card_reject'))).width,
          ),
        );
      });

      testWidgets(
        'both buttons carry the mockup radius, padding and label style',
        (tester) async {
          await pumpCard(tester, kind: 'in_review');

          final styles = <ButtonStyle>[
            tester
                .widget<FilledButton>(find.byKey(const Key('card_approve')))
                .style!,
            tester
                .widget<OutlinedButton>(find.byKey(const Key('card_reject')))
                .style!,
          ];

          for (final style in styles) {
            expect(
              style.shape!.resolve({}),
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            );
            expect(
              style.padding!.resolve({}),
              const EdgeInsets.symmetric(vertical: 11),
            );
            expect(style.textStyle!.resolve({})!.fontSize, 12.5);
            expect(style.textStyle!.resolve({})!.fontWeight, FontWeight.w600);
          }
        },
      );
    },
  );

  // Separate tests, not two taps in one: a SnackBar lingers ~4s, so tapping both in one
  // test would leave two 'RLY-88' texts on screen and fail findsOneWidget.
  group('the actions are visibly stubbed (RLY-88 owns the behavior)', () {
    testWidgets('Approve names where the behavior lands', (tester) async {
      await pumpCard(tester, kind: 'in_review');

      await tester.tap(find.byKey(const Key('card_approve')));
      await tester.pump();

      expect(find.text('Approve lands in RLY-88'), findsOneWidget);
    });

    testWidgets('Reject names where the behavior lands', (tester) async {
      await pumpCard(tester, kind: 'in_review');

      await tester.tap(find.byKey(const Key('card_reject')));
      await tester.pump();

      expect(find.text('Reject lands in RLY-88'), findsOneWidget);
    });
  });

  test('cardUrl builds the chromeless standalone card link', () {
    expect(
      CardScreen.cardUrl(
        cardRef: 'RLY-123',
        boardSlug: 'my-board',
        baseUrl: 'http://localhost:4003',
      ),
      'http://localhost:4003/cards/RLY-123?board=my-board&embed=1',
    );
  });
}
