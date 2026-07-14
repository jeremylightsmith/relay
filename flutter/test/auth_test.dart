import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/main.dart';

void main() {
  testWidgets('unauthenticated app is gated to the sign-in screen', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RelayApp()));
    await tester.pumpAndSettle();

    // Sign-in surface is shown (Google works; Apple present but disabled).
    expect(find.byKey(const Key('sign_in_google')), findsOneWidget);
    expect(find.byKey(const Key('sign_in_apple')), findsOneWidget);

    // The tab shell is NOT reachable until signed in.
    expect(find.text('Arriving soon'), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
  });
}
