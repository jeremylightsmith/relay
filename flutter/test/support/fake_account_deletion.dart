import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/app/messenger.dart';
import 'package:relay_mobile/app/theme.dart';
import 'package:relay_mobile/features/auth/apple_credential.dart';
import 'package:relay_mobile/features/auth/auth_controller.dart';
import 'package:relay_mobile/features/settings/account_deletion.dart';
import 'package:relay_mobile/features/settings/delete_account_page.dart';

import 'fake_auth.dart';

/// The task's fixture preview `P`: one shared board with two candidates
/// (oldest first), one solo board, a plan that ends and two runners.
DeletionPreview previewP({
  bool appleReauthRequired = false,
  List<OwnerCandidate>? alphaCandidates,
}) => DeletionPreview(
  sharedBoards: [
    SharedBoard(
      slug: 'alpha',
      name: 'Relay Engineering',
      memberCount: 4,
      candidates:
          alphaCandidates ??
          [
            OwnerCandidate(
              userId: 12,
              name: 'Ana Ruiz',
              avatarUrl: null,
              memberSince: DateTime(2026, 3, 1),
            ),
            OwnerCandidate(
              userId: 13,
              name: 'Kenji Ota',
              avatarUrl: null,
              memberSince: DateTime(2026, 6, 15),
            ),
          ],
    ),
  ],
  soloBoards: const [SoloBoard(slug: 'side', name: 'Side project')],
  planEnds: true,
  runners: const ['macbook-pro', 'ci-box'],
  appleReauthRequired: appleReauthRequired,
);

/// One recorded `deleteAccount` call.
typedef DeleteCall = ({Map<String, int> transfers, String? code});

/// Answers the deletion endpoints from memory and records every call.
///
/// [previews] are served in order (the last one repeats); an entry that is not
/// a [DeletionPreview] is thrown instead. [result] answers `deleteAccount` —
/// pass a [Completer]'s future to hold it open.
class FakeAccountDeletionRepository implements AccountDeletionRepository {
  FakeAccountDeletionRepository({
    required this.previews,
    Future<DeleteAccountResult>? result,
  }) : result = result ?? Future.value(const DeleteAccountDeleted());

  final List<Object> previews;
  Future<DeleteAccountResult> result;
  int fetchCalls = 0;
  final List<DeleteCall> deleteCalls = [];

  @override
  Future<DeletionPreview> fetchPreview() async {
    final next = previews[fetchCalls.clamp(0, previews.length - 1)];
    fetchCalls++;
    if (next is DeletionPreview) return next;
    throw next;
  }

  @override
  Future<DeleteAccountResult> deleteAccount({
    required Map<String, int> transfers,
    String? appleAuthorizationCode,
  }) {
    deleteCalls.add((transfers: transfers, code: appleAuthorizationCode));
    return result;
  }
}

/// Pumps [DeleteAccountPage] on an iPhone-sized surface, inside a MaterialApp
/// whose messenger is the app's [scaffoldMessengerKeyProvider] key, with the
/// network cut out. Returns the fake auth so tests can count sign-outs.
///
/// With [pushed], the page is pushed over a plain home route (as Settings
/// pushes it), so it has a back button and can be popped mid-request.
Future<FakeAuthController> pumpDeleteAccountPage(
  WidgetTester tester, {
  required FakeAccountDeletionRepository repo,
  AppleCredentialRequest? apple,
  bool settle = true,
  bool pushed = false,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final auth = FakeAuthController(
    const AuthState(
      status: AuthStatus.signedIn,
      user: {'id': 1, 'name': 'Dana Kim', 'email': 'dana@acme.co'},
      token: 'relayu_t',
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(() => auth),
        accountDeletionRepositoryProvider.overrideWithValue(repo),
        if (apple != null)
          appleCredentialRequestProvider.overrideWithValue(apple),
      ],
      child: Consumer(
        builder: (context, ref, _) => MaterialApp(
          theme: RelayTheme.light,
          scaffoldMessengerKey: ref.watch(scaffoldMessengerKeyProvider),
          home: pushed
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      key: const Key('test_open_delete_account'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const DeleteAccountPage(),
                        ),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                )
              : const DeleteAccountPage(),
        ),
      ),
    ),
  );
  if (pushed) {
    await tester.pump();
    await tester.tap(find.byKey(const Key('test_open_delete_account')));
  }
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return auth;
}

/// Types [text] into the confirm field.
Future<void> typeConfirm(WidgetTester tester, String text) async {
  final field = find.byKey(const Key('delete_account_confirm_field'));
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

/// Taps the Delete account button.
Future<void> tapSubmit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('delete_account_submit')));
  await tester.pump();
}

/// The Delete account button, for its `onPressed`.
FilledButton submitButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('delete_account_submit')));

/// Every piece of text rendered under [finder], joined by a space — reads
/// `Text` and `Text.rich` alike, so a line split into styled spans still reads
/// as one sentence.
String textUnder(WidgetTester tester, Finder finder) => tester
    .widgetList<RichText>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    )
    .map((r) => r.text.toPlainText())
    .join(' ');
