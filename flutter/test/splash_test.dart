import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/splash_screen.dart';

void main() {
  testWidgets('the restore hold shows the Hamaca wordmark', (tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: RelayTheme.light, home: const SplashScreen()),
    );
    // pump(), not pumpAndSettle(): the indeterminate spinner never settles.
    await tester.pump();

    expect(find.text('Hamaca'), findsOneWidget);
    expect(find.text('Relay'), findsNothing);
  });
}
