// RE466: Settings' ACCOUNT › Plan row — status only. No buy button, no link
// out, nothing tappable (App Store rules); hidden when billing is off or the
// server predates it.
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/board/board_prefs.dart';
import 'package:relay_mobile/features/boards/boards_repository.dart';
import 'package:relay_mobile/features/needs_you/feed_repository.dart';
import 'package:relay_mobile/features/settings/external_url_launcher.dart';
import 'package:relay_mobile/features/settings/plan_status.dart';
import 'package:relay_mobile/features/settings/settings_screen.dart';

import '../../needs_you_screen_test.dart' show FakeFeedRepository;
import '../../support/fake_auth.dart';
import '../../support/fake_boards.dart';
import 'suggest_idea_test.dart' show RecordingLaunch;

const _user = {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'};

const _section = Key('settings_account_section');
const _header = Key('settings_account_header');
const _planRow = Key('settings_plan_row');
const _planValue = Key('settings_plan_value');
const _manage = Key('settings_manage_billing');
const _manageText = 'Manage billing on relay on the web.';

PlanStatus? billing(String? standing, {String? through, bool enabled = true}) =>
    PlanStatus.fromJson({
      'enabled': enabled,
      'standing': standing,
      'through': through,
    });

/// Counts every push the app's Navigator sees after the first route.
class PushCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) pushes++;
  }
}

Future<void> pumpSettings(
  WidgetTester tester, {
  required PlanStatus? billing,
  RecordingLaunch? launcher,
  PushCounter? observer,
}) async {
  final auth = FakeAuthController(
    AuthState(
      status: AuthStatus.signedIn,
      user: _user,
      token: 'relayu_t',
      billing: billing,
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        boardPrefsProvider.overrideWithValue(InMemoryBoardPrefs('mkt')),
        boardsRepositoryProvider.overrideWithValue(
          FakeBoardsRepository(
            boards: [makeBoard('mkt', name: 'Marketing site')],
          ),
        ),
        feedRepositoryProvider.overrideWithValue(FakeFeedRepository()),
        externalUrlLauncherProvider.overrideWithValue(
          (launcher ?? RecordingLaunch(true)).call,
        ),
      ],
      child: MaterialApp(
        theme: RelayTheme.light,
        navigatorObservers: [?observer],
        home: const SettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder inSection(Finder matching) =>
    find.descendant(of: find.byKey(_section), matching: matching);

void main() {
  testWidgets('an active plan shows ACCOUNT › Plan and the manage line', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      billing: billing('active', through: '2026-05-03'),
    );

    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('Plan'), findsOneWidget);
    expect(find.text('Active · through May 3'), findsOneWidget);
    expect(find.text(_manageText), findsOneWidget);

    final header = tester.widget<Text>(find.byKey(_header));
    expect(header.data, 'ACCOUNT');
    expect(header.style!.fontSize, 11);
    expect(header.style!.fontFamily, 'monospace');
  });

  testWidgets('the section matches the mockup: outlined card, padding, '
      'dividers, 14px manage line', (tester) async {
    await pumpSettings(
      tester,
      billing: billing('active', through: '2026-05-03'),
    );
    final scheme = Theme.of(tester.element(find.byKey(_section))).colorScheme;

    final card =
        tester.widget<Container>(find.byKey(_section)).decoration!
            as BoxDecoration;
    expect((card.border! as Border).top.color, scheme.outlineVariant);
    expect(card.borderRadius, BorderRadius.circular(12));
    expect(card.color, scheme.surface);

    final header = tester.widget<Text>(find.byKey(_header));
    expect(header.style!.color, scheme.onSurfaceVariant);

    final plan = tester.widget<Text>(find.text('Plan'));
    expect(plan.style!.fontSize, 14);
    expect(plan.style!.color, scheme.onSurface);

    final manage = tester.widget<Text>(find.byKey(_manage));
    expect(manage.data, _manageText);
    expect(manage.style!.fontSize, 14);
    expect(manage.style!.color, scheme.onSurfaceVariant);

    expect(
      tester.getSize(find.byKey(_planRow)).width,
      tester.getSize(find.byKey(_section)).width - 2, // inside the 1px border
    );
    expect(inSection(find.byType(Divider)), findsNWidgets(2));
  });

  testWidgets('the section sits between the identity block and Log out', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      billing: billing('active', through: '2026-05-03'),
    );

    final top = tester.getTopLeft(find.byKey(_section)).dy;
    final identityBottom = [
      const Key('settings_avatar'),
      const Key('settings_email'),
    ].map((k) => tester.getBottomLeft(find.byKey(k)).dy).reduce(max);
    expect(top - identityBottom, 24);
    expect(
      tester.getTopLeft(find.byKey(const Key('settings_log_out'))).dy -
          tester.getBottomLeft(find.byKey(_section)).dy,
      24,
    );
  });

  testWidgets('nothing in the section is tappable or links out', (
    tester,
  ) async {
    final launcher = RecordingLaunch(true);
    final observer = PushCounter();
    await pumpSettings(
      tester,
      billing: billing('active', through: '2026-05-03'),
      launcher: launcher,
      observer: observer,
    );

    expect(inSection(find.byType(ButtonStyleButton)), findsNothing);
    expect(inSection(find.byType(InkWell)), findsNothing);
    expect(inSection(find.byType(GestureDetector)), findsNothing);
    expect(inSection(find.byIcon(Icons.open_in_new)), findsNothing);
    expect(inSection(find.byIcon(Icons.chevron_right)), findsNothing);

    await tester.tap(find.byKey(_planRow));
    await tester.tap(find.byKey(_manage));
    await tester.pumpAndSettle();

    expect(observer.pushes, 0);
    expect(launcher.calls, isEmpty);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('billing switched off hides the whole section', (tester) async {
    await pumpSettings(tester, billing: billing(null, enabled: false));

    expect(find.byKey(_section), findsNothing);
    expect(find.text('Plan'), findsNothing);
    expect(find.text(_manageText), findsNothing);
  });

  testWidgets('an old server with no billing hides the whole section', (
    tester,
  ) async {
    await pumpSettings(tester, billing: null);

    expect(find.byKey(_section), findsNothing);
    expect(find.text('Plan'), findsNothing);
    expect(find.text(_manageText), findsNothing);
    expect(find.byKey(const Key('settings_log_out')), findsOneWidget);
  });

  for (final (standing, through, label) in [
    ('free', null, 'Free'),
    ('past_due', null, 'Past due'),
    ('cancelled', '2026-05-03', 'Cancelled · through May 3'),
    ('comped', null, 'Comped'),
    ('paused', null, 'Paused'),
  ]) {
    testWidgets('$standing shows "$label"', (tester) async {
      await pumpSettings(tester, billing: billing(standing, through: through));

      expect(tester.widget<Text>(find.byKey(_planValue)).data, label);
    });
  }

  Color? valueColor(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(_planValue)).style!.color;

  BoxDecoration pill(WidgetTester tester) =>
      tester
              .widget<Container>(
                find
                    .ancestor(
                      of: find.byKey(_planValue),
                      matching: find.byType(Container),
                    )
                    .first,
              )
              .decoration!
          as BoxDecoration;

  testWidgets('active is a soft green pill', (tester) async {
    await pumpSettings(
      tester,
      billing: billing('active', through: '2026-05-03'),
    );

    expect(valueColor(tester), RelayTheme.relayDone);
    expect(tester.widget<Text>(find.byKey(_planValue)).style!.fontSize, 12);
    expect(pill(tester).color, RelayTheme.relayDone.withValues(alpha: 0.15));
    expect(pill(tester).borderRadius, BorderRadius.circular(999));
  });

  testWidgets('paused is an amber pill', (tester) async {
    await pumpSettings(tester, billing: billing('paused'));

    expect(valueColor(tester), RelayTheme.relayBlocked);
    expect(pill(tester).color, RelayTheme.relayBlocked.withValues(alpha: 0.15));
  });

  for (final (standing, tone) in <(String, Color Function(ColorScheme))>[
    ('comped', (_) => RelayTheme.relayDone),
    ('past_due', (_) => RelayTheme.relayBlocked),
    ('free', (s) => s.primary),
    ('cancelled', (s) => s.onSurfaceVariant),
  ]) {
    testWidgets('$standing gets its mockup tone', (tester) async {
      await pumpSettings(tester, billing: billing(standing));
      final scheme = Theme.of(tester.element(find.byKey(_section))).colorScheme;

      expect(valueColor(tester), tone(scheme));
      expect(pill(tester).color, tone(scheme).withValues(alpha: 0.15));
    });
  }
}
