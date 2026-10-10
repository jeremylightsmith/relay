import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/widgets/headered_sheet.dart';

/// The phone surface from the card's Global Constraints: a 390×844 screen at
/// dpr 1, a 47px top / 34px bottom safe area and (unless [keyboard] is false) a
/// 300px simulated keyboard. The visible area is then logical y ∈ [47, 544].
void usePhone(WidgetTester tester, {bool keyboard = true}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard ? 300 : 0);
  addTearDown(tester.view.reset);
}

const _cancel = Key('t_cancel');
const _title = Key('t_title');
const _action = Key('t_action');

/// 2400px of content. Each row carries a child because a childless SizedBox
/// never answers a hit test, so `.hitTestable()` could never find it.
List<Widget> _rows() => [
  for (var i = 0; i < 40; i++)
    SizedBox(height: 60, key: Key('row_$i'), child: Text('row $i')),
];

/// Hosts a [HeaderedSheet] in a real `showModalBottomSheet` (scroll-controlled,
/// safe-area aware) and opens it, so the modal's real constraints apply.
Future<void> openSheet(
  WidgetTester tester, {
  required List<Widget> body,
  Widget? action,
  VoidCallback? onAction,
  bool showHandle = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: RelayTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (ctx) => HeaderedSheet(
                  showHandle: showHandle,
                  leading: SheetHeaderCancel(
                    key: _cancel,
                    onPressed: () => Navigator.pop(ctx),
                  ),
                  title: const Text('Title', key: _title),
                  action:
                      action ??
                      SheetHeaderAction(
                        key: _action,
                        label: 'Go',
                        onPressed: onAction ?? () {},
                      ),
                  body: body,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  // A busy action's spinner animates forever, so pumpAndSettle would time out;
  // pump past the sheet's entrance animation instead.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

FilledButton _innerButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.descendant(of: find.byKey(_action), matching: find.byType(FilledButton)),
);

void main() {
  testWidgets('1. a short body with no keyboard is a compact sheet', (
    tester,
  ) async {
    usePhone(tester, keyboard: false);
    await openSheet(tester, body: const [Text('short')]);

    expect(tester.getSize(find.byType(HeaderedSheet)).height, lessThan(200));
    expect(find.text('short').hitTestable(), findsOneWidget);
  });

  testWidgets('2. the action stays visible and tappable above the keyboard', (
    tester,
  ) async {
    usePhone(tester);
    var taps = 0;
    await openSheet(tester, body: _rows(), onAction: () => taps++);

    expect(find.byKey(_action).hitTestable(), findsOneWidget);
    final rect = tester.getRect(find.byKey(_action));
    expect(rect.top, greaterThanOrEqualTo(47));
    expect(rect.bottom, lessThanOrEqualTo(544));

    await tester.tap(find.byKey(_action));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('3. a long sheet never grows past the top safe area', (
    tester,
  ) async {
    usePhone(tester);
    await openSheet(tester, body: _rows());

    final rect = tester.getRect(find.byType(HeaderedSheet));
    expect(rect.top, greaterThanOrEqualTo(47));
    expect(rect.bottom, lessThanOrEqualTo(844));
  });

  testWidgets('4. the body scrolls under a fixed header', (tester) async {
    usePhone(tester);
    await openSheet(tester, body: _rows());

    final titleBefore = tester.getRect(find.byKey(_title));
    final actionBefore = tester.getRect(find.byKey(_action));
    expect(find.byKey(const Key('row_39')).hitTestable(), findsNothing);

    // The body viewport between the header and the keyboard is ~430px, so
    // reaching the last of 2400px of rows takes more than one 1500px drag.
    for (var i = 0; i < 2; i++) {
      await tester.drag(
        find.byKey(const Key('sheet_body')),
        const Offset(0, -1500),
      );
      await tester.pumpAndSettle();
    }

    expect(find.byKey(const Key('row_39')).hitTestable(), findsOneWidget);
    expect(tester.getRect(find.byKey(_title)), titleBefore);
    expect(tester.getRect(find.byKey(_action)), actionBefore);
  });

  testWidgets('5. header reads cancel | centred title | action', (
    tester,
  ) async {
    usePhone(tester);
    await openSheet(tester, body: const [Text('short')]);

    final cancel = tester.getCenter(find.byKey(_cancel));
    final title = tester.getCenter(find.byKey(_title));
    final action = tester.getCenter(find.byKey(_action));

    expect(cancel.dx, lessThan(title.dx));
    expect(title.dx, lessThan(action.dx));
    expect((title.dx - 195).abs(), lessThanOrEqualTo(40));
    expect((cancel.dy - title.dy).abs(), lessThanOrEqualTo(2));
    expect((action.dy - title.dy).abs(), lessThanOrEqualTo(2));
  });

  testWidgets('6. the action is a Human-blue filled button with its label', (
    tester,
  ) async {
    usePhone(tester);
    await openSheet(tester, body: const [Text('short')]);

    final button = _innerButton(tester);
    expect(button.style!.backgroundColor!.resolve({}), RelayTheme.relayHuman);
    expect(find.text('Go'), findsOneWidget);
  });

  testWidgets('7. a busy action is disabled and shows a spinner', (
    tester,
  ) async {
    usePhone(tester);
    await openSheet(
      tester,
      body: const [Text('short')],
      action: SheetHeaderAction(
        key: _action,
        label: 'Go',
        onPressed: () {},
        busy: true,
      ),
    );

    expect(_innerButton(tester).onPressed, isNull);
    expect(
      find.descendant(
        of: find.byKey(_action),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(find.text('Go'), findsNothing);
  });

  testWidgets('8. a null onPressed disables the action but keeps its label', (
    tester,
  ) async {
    usePhone(tester);
    await openSheet(
      tester,
      body: const [Text('short')],
      action: const SheetHeaderAction(
        key: _action,
        label: 'Go',
        onPressed: null,
      ),
    );

    expect(_innerButton(tester).onPressed, isNull);
    expect(find.text('Go'), findsOneWidget);
  });

  group('9. grab handle', () {
    Finder handle() => find.descendant(
      of: find.byKey(const Key('sheet_header')),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints == BoxConstraints.tight(const Size(32, 4)),
      ),
    );

    testWidgets('is drawn in the header when showHandle is true', (
      tester,
    ) async {
      usePhone(tester);
      await openSheet(tester, body: const [Text('short')], showHandle: true);
      expect(handle(), findsOneWidget);
    });

    testWidgets('is absent by default', (tester) async {
      usePhone(tester);
      await openSheet(tester, body: const [Text('short')]);
      expect(handle(), findsNothing);
    });
  });

  testWidgets('10. Cancel closes the sheet', (tester) async {
    usePhone(tester);
    await openSheet(tester, body: const [Text('short')]);
    expect(find.byType(HeaderedSheet), findsOneWidget);

    await tester.tap(find.byKey(_cancel));
    await tester.pumpAndSettle();

    expect(find.byType(HeaderedSheet), findsNothing);
  });
}
