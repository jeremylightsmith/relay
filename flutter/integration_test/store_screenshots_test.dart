import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:relay_mobile/app/embedded_webview.dart';
import 'package:relay_mobile/app/router.dart';
import 'package:relay_mobile/config.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/auth/session_store.dart';
import 'package:relay_mobile/features/board/board_screen.dart';
import 'package:relay_mobile/features/boards/current_board.dart';
import 'package:relay_mobile/features/card/card_screen.dart';
import 'package:relay_mobile/main.dart';

/// Drives the real app to the four App Store screens (RE479) against a local
/// dev server seeded with the "Forkful" board. It takes no screenshots itself:
/// the board and card body are LiveView WKWebViews Flutter can't capture, and
/// the status bar isn't part of the Flutter surface. Instead it prints
/// `HAMACA_SHOT <name>` once each screen has settled and holds it, and
/// bin/capture_store_screenshots.sh runs `xcrun simctl io … screenshot` on
/// each marker.
///
/// Prerequisites:
///   mix run priv/repo/store_screenshot_seeds.exs
///   mix phx.server                       (the dev server on :4003)
///   an iPhone 6.9" simulator, booted
/// Run it through the host script, which overrides the status bar and
/// captures each marker (see flutter/docs/DEPLOYMENT.md § "Store screenshots"):
///   bin/capture_store_screenshots.sh [SIMULATOR_UDID]
/// which runs:
///   flutter test integration_test/store_screenshots_test.dart -d `<udid>`
///     --dart-define=RELAY_BASE_URL=http://localhost:4003
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'walks Needs you, Board, Review and Answer for the store shots',
    (tester) async {
      // There is no native dev login: sign in the way a returning user does, by
      // restoring a persisted `_hamaca_key`. /dev/login mints one for the dev
      // user (the Forkful board's owner); the launch restore verifies it.
      await SecureSessionStore().write(await _devSessionCookie());

      final board = _EmbeddedPage(
        (context) => BoardScreen.boardUrl(slug: _board),
      );
      final card = _EmbeddedPage(_cardUrl);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            boardBodyBuilderProvider.overrideWithValue(board.build),
            cardBodyBuilderProvider.overrideWithValue(card.build),
          ],
          child: const RelayApp(),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(RelayApp)),
      );

      await _waitFor(
        tester,
        () => container.read(authProvider).signedIn,
        'the restored dev session to sign in',
      );
      await container.read(currentBoardProvider.notifier).switchTo(_board);
      final router = container.read(routerProvider);

      router.go('/needs-you');
      await _waitForText(tester, 'Redesign the recipe page');
      await _shot(tester, '01_needs_you');

      router.go('/board');
      await _waitFor(tester, () => board.loaded, 'the board to load');
      await _pumpFor(tester, const Duration(seconds: 3));
      // A person taps the Design chip: an agent mocking up, a question and a
      // review side by side.
      await board.tap(
        "[...document.querySelectorAll('[data-chip-stage-id]')]"
            ".find((c) => c.textContent.trim().startsWith('Design'))",
        'the Design stage chip',
      );
      await _shot(tester, '02_board', settle: const Duration(seconds: 5));

      await _openFromInbox(tester, router, card, 'Redesign the recipe page');
      // A person taps mockup A's tile; the page patches to its viewer, and the
      // native Approve / Reject bar stays underneath. The shot is the viewer,
      // not the card page: no screen shows the card header and a large
      // mockup together, and an obviously real recipe page matters more than
      // the card title (decided on RE479, 2026-10-26). On the card page the
      // mockups are unreadable thumbnails.
      await card.tap(
        "document.querySelector('a[href*=\"mockup=\"]')",
        "mockup A's tile",
      );
      await _shot(tester, '03_review', settle: const Duration(seconds: 8));

      await _openFromInbox(tester, router, card, 'Sync saved recipes');
      await _shot(tester, '04_answer', settle: const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

const _board = 'forkful';

/// The card page's URL, built the way CardScreen builds it. CardScreen calls
/// its body builder with its own State's context.
String _cardUrl(BuildContext context) {
  final widget = context.widget;
  final screen = widget is CardScreen
      ? widget
      : context.findAncestorWidgetOfExactType<CardScreen>()!;
  return CardScreen.cardUrl(
    cardRef: screen.cardRef,
    boardSlug: screen.boardSlug,
    backLabel: screen.backLabel,
    navContext: screen.navContext,
  );
}

/// A board or card body: the same embedded LiveView page and settings the app
/// builds (`BoardScreen.boardUrl` / `CardScreen.cardUrl`,
/// `embeddedWebViewSettings`), through the router's body-builder seams — so
/// the test holds the webview's controller, knows when the page has loaded,
/// and can tap inside it, which a Flutter tap can't do to a native WKWebView.
class _EmbeddedPage {
  _EmbeddedPage(this._url);

  final String Function(BuildContext context) _url;
  InAppWebViewController? _controller;
  bool loaded = false;

  Widget build(BuildContext context) => InAppWebView(
    initialSettings: embeddedWebViewSettings(),
    initialUrlRequest: URLRequest(url: WebUri(_url(context))),
    onWebViewCreated: (controller) => _controller = controller,
    onLoadStop: (_, _) => loaded = true,
  );

  /// Clicks the element [elementJs] evaluates to, as a person's tap would.
  Future<void> tap(String elementJs, String what) async {
    final clicked = await _controller!.evaluateJavascript(
      source: '(() => { const el = $elementJs; el?.click(); return !!el; })()',
    );
    if (clicked != true) fail('Found no $what to tap.');
  }
}

/// Back to the inbox, then tap [title]'s row — the way a person opens a card —
/// and wait for its page to load.
Future<void> _openFromInbox(
  WidgetTester tester,
  GoRouter router,
  _EmbeddedPage card,
  String title,
) async {
  router.go('/needs-you');
  await _waitForText(tester, title);
  // Let the route transition finish, or the tap lands on the outgoing page.
  await _pumpFor(tester, const Duration(seconds: 2));
  card.loaded = false;
  await tester.tap(find.text(title));
  await _waitFor(tester, () => card.loaded, 'the "$title" card to load');
}

/// The dev user's session cookie value. `/dev/login` signs in and redirects
/// with a "Signed in as …" flash in the session; follow its redirects, as a
/// browser would, so the flash is spent here rather than over the Board shot.
Future<String> _devSessionCookie() async {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.baseUrl,
      followRedirects: false,
      validateStatus: (_) => true,
    ),
  );
  final login = await dio.get<void>('/dev/login');
  final minted = _sessionCookieIn(login);
  if (minted == null) {
    throw StateError(
      'GET ${AppConfig.baseUrl}/dev/login set no $hamacaSessionCookie cookie '
      '(status ${login.statusCode}). Is `mix phx.server` running?',
    );
  }
  var session = minted;

  // Follow the redirects (to /board) until a page renders; that render spends
  // the flash and answers with a fresh cookie.
  var location = login.headers.value('location');
  for (var hop = 0; location != null && hop < 5; hop++) {
    final resp = await dio.get<void>(
      location,
      options: Options(headers: {'cookie': '$hamacaSessionCookie=$session'}),
    );
    session = _sessionCookieIn(resp) ?? session;
    location = (resp.statusCode ?? 0) ~/ 100 == 3
        ? resp.headers.value('location')
        : null;
  }
  return session;
}

String? _sessionCookieIn(Response<void> resp) {
  for (final raw in resp.headers.map['set-cookie'] ?? const <String>[]) {
    final cookie = io.Cookie.fromSetCookieValue(raw);
    if (cookie.name == hamacaSessionCookie) return cookie.value;
  }
  return null;
}

/// Lets the screen (and its webview) settle, prints the capture marker, then
/// holds still while the host script screenshots the simulator.
Future<void> _shot(
  WidgetTester tester,
  String name, {
  Duration settle = const Duration(seconds: 4),
}) async {
  await _pumpFor(tester, settle);
  // The host script greps the test's stdout for exactly this line.
  // ignore: avoid_print
  print('HAMACA_SHOT $name');
  await _pumpFor(tester, const Duration(seconds: 5));
}

Future<void> _waitForText(WidgetTester tester, String text) => _waitFor(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  '"$text" on screen',
);

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done,
  String what, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after ${timeout.inSeconds}s waiting for $what.');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// `pumpAndSettle` never settles over a live webview or a spinner; pump on a
/// fixed clock instead.
Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
