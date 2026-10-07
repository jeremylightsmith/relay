import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/card/card_nav_context.dart';
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
    ProviderScope(
      child: MaterialApp(
        theme: RelayTheme.light,
        home: CardScreen(
          cardRef: 'RLY-42',
          boardSlug: 'marketing',
          kind: kind,
          bodyBuilder: tallBody,
        ),
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
        'both buttons are 50px tall with 17/600 labels (RE393 iOS bar)',
        (tester) async {
          await pumpCard(tester, kind: 'in_review');

          for (final key in const [Key('card_reject'), Key('card_approve')]) {
            expect(tester.getSize(find.byKey(key)).height, 50);
          }
          final styles = <ButtonStyle>[
            tester
                .widget<FilledButton>(find.byKey(const Key('card_approve')))
                .style!,
            tester
                .widget<OutlinedButton>(find.byKey(const Key('card_reject')))
                .style!,
          ];
          for (final style in styles) {
            expect(style.textStyle!.resolve({})!.fontSize, 17);
            expect(style.textStyle!.resolve({})!.fontWeight, FontWeight.w600);
          }
        },
      );

      testWidgets(
        'the buttons sit 10px apart, keep 10:14, and carry radius 12',
        (tester) async {
          await pumpCard(tester, kind: 'in_review');

          final reject = tester.getRect(find.byKey(const Key('card_reject')));
          final approve = tester.getRect(find.byKey(const Key('card_approve')));
          expect(approve.left - reject.right, 10);
          expect(approve.width / reject.width, closeTo(1.4, 0.01));

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
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            );
          }
        },
      );

      testWidgets('the bar pads 16 horizontally and 10 on top', (tester) async {
        await pumpCard(tester, kind: 'in_review');

        final bar = tester.getRect(find.byType(CardReviewBar));
        final reject = tester.getRect(find.byKey(const Key('card_reject')));
        final approve = tester.getRect(find.byKey(const Key('card_approve')));
        expect(reject.left - bar.left, 16);
        expect(bar.right - approve.right, 16);
        // The hairline is painted, not laid out — the padding starts at the top.
        expect(reject.top - bar.top, 10);
      });
    },
  );

  group('cardUrl', () {
    test('builds the chromeless standalone card link', () {
      expect(
        CardScreen.cardUrl(
          cardRef: 'RLY-123',
          boardSlug: 'my-board',
          baseUrl: 'http://localhost:4003',
        ),
        'http://localhost:4003/cards/RLY-123?board=my-board&embed=1',
      );
    });

    test('carries the encoded back label for the web nav bar', () {
      expect(
        CardScreen.cardUrl(
          cardRef: 'RLY-123',
          boardSlug: 'my-board',
          backLabel: 'Needs you',
          baseUrl: 'http://localhost:4003',
        ),
        'http://localhost:4003/cards/RLY-123?board=my-board&embed=1&back=Needs+you',
      );
    });

    test('an empty back label adds no back param', () {
      expect(
        CardScreen.cardUrl(
          cardRef: 'RLY-123',
          boardSlug: 'my-board',
          backLabel: '',
          baseUrl: 'http://localhost:4003',
        ),
        'http://localhost:4003/cards/RLY-123?board=my-board&embed=1',
      );
    });

    group('nav (RE400)', () {
      const items = [
        CardNavItem(ref: 'RLY-1', boardSlug: 'my-board'),
        CardNavItem(ref: 'RLY-123', boardSlug: 'my-board'),
        CardNavItem(ref: 'RLY-3', boardSlug: 'my-board'),
      ];
      CardNavContext ctx(String at, [List<CardNavItem> list = items]) =>
          CardNavContext.seed(items: list, currentRef: at)!;
      String url({CardNavContext? navContext, String? backLabel}) =>
          CardScreen.cardUrl(
            cardRef: 'RLY-123',
            boardSlug: 'my-board',
            backLabel: backLabel,
            navContext: navContext,
            baseUrl: 'http://localhost:4003',
          );
      const base = 'http://localhost:4003/cards/RLY-123?board=my-board&embed=1';

      test('no context adds no nav param', () {
        expect(url(), base);
      });

      test('the first card names only next', () {
        expect(url(navContext: ctx('RLY-1')), '$base&nav=next');
      });

      test('a middle card names prev,next', () {
        expect(url(navContext: ctx('RLY-123')), '$base&nav=prev,next');
      });

      test('the last card names only prev', () {
        expect(url(navContext: ctx('RLY-3')), '$base&nav=prev');
      });

      test('a one-item context adds no nav param', () {
        expect(url(navContext: ctx('RLY-123', [items[1]])), base);
      });

      test('nav follows the back label', () {
        expect(
          url(navContext: ctx('RLY-123'), backLabel: 'Needs you'),
          '$base&back=Needs+you&nav=prev,next',
        );
      });
    });
  });
}
