// Smoke test for the spike: the native inbox renders its "Needs you" list.
import 'package:flutter_test/flutter_test.dart';

import 'package:relay_mobile/main.dart';

void main() {
  testWidgets('native inbox renders needs-you rows', (WidgetTester tester) async {
    await tester.pumpWidget(const RelaySpikeApp());

    expect(find.text('Needs you'), findsOneWidget);
    expect(find.text('Multi-region data residency'), findsOneWidget);
    expect(find.text('NEEDS INPUT'), findsOneWidget);
  });
}
