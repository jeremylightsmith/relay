// RE509 · SET-03: the pushed Delete account page — preview, consequences, the
// DELETE-to-confirm rule, Apple re-auth, busy/error states and the sign-out.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/settings/account_deletion.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../support/fake_account_deletion.dart';

const _errorText =
    "Couldn't delete your account. Check your connection and try again. "
    'Nothing was deleted.';

Finder _key(String k) => find.byKey(Key(k));

void main() {
  testWidgets('lists the hand-offs and every consequence (scenario 3)', (
    tester,
  ) async {
    await pumpDeleteAccountPage(
      tester,
      repo: FakeAccountDeletionRepository(previews: [previewP()]),
    );

    expect(_key('delete_account_page'), findsOneWidget);
    expect(find.text('Delete account'), findsWidgets);
    expect(find.text("BOARDS YOU'LL HAND OFF"), findsOneWidget);
    expect(find.text('DELETED WITH YOUR ACCOUNT'), findsOneWidget);

    final row = _key('delete_account_handoff_alpha');
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Relay Engineering')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('4 members')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _key('delete_account_owner_alpha'),
        matching: find.text('Ana Ruiz'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('They become the owner and pay for the board from now on.'),
      findsOneWidget,
    );

    final solo = textUnder(tester, _key('delete_account_solo_side'));
    expect(solo, contains('Side project'));
    expect(solo, contains(': only you use it'));
    expect(
      textUnder(tester, _key('delete_account_plan')),
      contains("Your Pro plan ends now and won't be refunded"),
    );
    expect(
      textUnder(tester, _key('delete_account_runners')),
      contains('2 runners you started will stop: macbook-pro, ci-box'),
    );
    expect(
      textUnder(tester, _key('delete_account_kept')),
      contains('Your comments and votes stay, shown as "Deleted user"'),
    );
    // Not an Apple account, no attempt yet.
    expect(_key('delete_account_apple_note'), findsNothing);
    expect(_key('delete_account_error'), findsNothing);
  });

  testWidgets('the intro copy and the confirm label render', (tester) async {
    await pumpDeleteAccountPage(
      tester,
      repo: FakeAccountDeletionRepository(previews: [previewP()]),
    );

    expect(
      find.text('This permanently deletes your Hamaca account.'),
      findsOneWidget,
    );
    expect(
      find.text("It happens right away and can't be undone."),
      findsOneWidget,
    );
    expect(
      find.textContaining('Type DELETE to confirm', findRichText: true),
      findsOneWidget,
    );
    final field = tester.widget<TextField>(
      _key('delete_account_confirm_field'),
    );
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.textCapitalization, TextCapitalization.characters);
  });

  testWidgets(
    'an empty preview omits hand-offs and the DELETED header (scenario 4)',
    (tester) async {
      await pumpDeleteAccountPage(
        tester,
        repo: FakeAccountDeletionRepository(
          previews: [
            const DeletionPreview(
              sharedBoards: [],
              soloBoards: [],
              planEnds: false,
              runners: [],
              appleReauthRequired: false,
            ),
          ],
        ),
      );

      expect(_key('delete_account_handoffs'), findsNothing);
      expect(find.text("BOARDS YOU'LL HAND OFF"), findsNothing);
      expect(find.text('DELETED WITH YOUR ACCOUNT'), findsNothing);
      expect(_key('delete_account_plan'), findsNothing);
      expect(_key('delete_account_runners'), findsNothing);
      expect(_key('delete_account_kept'), findsOneWidget);
    },
  );

  testWidgets('Delete enables only on exactly DELETE (scenario 5)', (
    tester,
  ) async {
    await pumpDeleteAccountPage(
      tester,
      repo: FakeAccountDeletionRepository(previews: [previewP()]),
    );
    expect(submitButton(tester).onPressed, isNull);

    await typeConfirm(tester, 'delete');
    expect(submitButton(tester).onPressed, isNull);

    await typeConfirm(tester, 'DELETE');
    expect(submitButton(tester).onPressed, isNotNull);

    await typeConfirm(tester, 'DELETE ');
    expect(submitButton(tester).onPressed, isNull);
  });

  testWidgets('submits the chosen owner and no Apple code (scenario 7)', (
    tester,
  ) async {
    final repo = FakeAccountDeletionRepository(
      previews: [previewP()],
      result: Completer<DeleteAccountResult>().future,
    );
    await pumpDeleteAccountPage(tester, repo: repo);

    await tester.tap(_key('delete_account_owner_alpha'));
    await tester.pumpAndSettle();
    await tester.tap(_key('owner_picker_option_13'));
    await tester.pumpAndSettle();
    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);

    expect(repo.deleteCalls, hasLength(1));
    expect(repo.deleteCalls.single.transfers, {'alpha': 13});
    expect(repo.deleteCalls.single.code, isNull);
  });

  testWidgets('cancelling Apple re-auth is a quiet no-op (scenario 8)', (
    tester,
  ) async {
    final repo = FakeAccountDeletionRepository(
      previews: [previewP(appleReauthRequired: true)],
    );
    final auth = await pumpDeleteAccountPage(
      tester,
      repo: repo,
      apple: (_) async => throw const SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.canceled,
        message: 'x',
      ),
    );

    expect(_key('delete_account_apple_note'), findsOneWidget);
    expect(
      find.text(
        'Next, Apple asks you to sign in once more so we can disconnect '
        'Hamaca from your Apple ID.',
      ),
      findsOneWidget,
    );

    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(_key('delete_account_error'), findsNothing);
    expect(repo.deleteCalls, isEmpty);
    expect(auth.deletedSignOutCalls, 0);
    expect(submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('any other Apple failure shows the error alert', (tester) async {
    final repo = FakeAccountDeletionRepository(
      previews: [previewP(appleReauthRequired: true)],
    );
    await pumpDeleteAccountPage(
      tester,
      repo: repo,
      apple: (_) async => throw const SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.failed,
        message: 'x',
      ),
    );

    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(_key('delete_account_error'), findsOneWidget);
    expect(repo.deleteCalls, isEmpty);
    expect(submitButton(tester).onPressed, isNotNull);
  });

  // sign_in_with_apple types `authorizationCode` as non-null, so "no code"
  // arrives as an empty string.
  testWidgets('an empty Apple authorization code shows the error alert', (
    tester,
  ) async {
    final repo = FakeAccountDeletionRepository(
      previews: [previewP(appleReauthRequired: true)],
    );
    await pumpDeleteAccountPage(
      tester,
      repo: repo,
      apple: (_) async => const AuthorizationCredentialAppleID(
        userIdentifier: 'u',
        givenName: null,
        familyName: null,
        email: null,
        authorizationCode: '',
        identityToken: 't',
        state: null,
      ),
    );

    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(_key('delete_account_error'), findsOneWidget);
    expect(repo.deleteCalls, isEmpty);
  });

  testWidgets('sends the fresh Apple authorization code (scenario 9)', (
    tester,
  ) async {
    final repo = FakeAccountDeletionRepository(
      previews: [previewP(appleReauthRequired: true)],
      result: Completer<DeleteAccountResult>().future,
    );
    String? hashedNonce;
    await pumpDeleteAccountPage(
      tester,
      repo: repo,
      apple: (nonce) async {
        hashedNonce = nonce;
        return const AuthorizationCredentialAppleID(
          userIdentifier: 'u',
          givenName: null,
          familyName: null,
          email: null,
          authorizationCode: 'code-xyz',
          identityToken: 't',
          state: null,
        );
      },
    );

    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);
    await tester.pump();

    expect(repo.deleteCalls.single.code, 'code-xyz');
    expect(repo.deleteCalls.single.transfers, {'alpha': 12});
    // sha256 hex of a fresh raw nonce.
    expect(hashedNonce, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  testWidgets('busy, then a failure keeps the input and alerts (scenario 10)', (
    tester,
  ) async {
    final pending = Completer<DeleteAccountResult>();
    final repo = FakeAccountDeletionRepository(
      previews: [previewP()],
      result: pending.future,
    );
    await pumpDeleteAccountPage(tester, repo: repo);

    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);

    expect(_key('delete_account_spinner'), findsOneWidget);
    expect(submitButton(tester).onPressed, isNull);
    expect(
      tester.widget<TextField>(_key('delete_account_confirm_field')).enabled,
      isFalse,
    );
    expect(
      tester.widget<TextButton>(_key('delete_account_cancel')).onPressed,
      isNull,
    );
    // The owner chip is locked too.
    await tester.tap(_key('delete_account_owner_alpha'));
    await tester.pump();
    expect(find.byKey(const Key('owner_picker_sheet')), findsNothing);

    pending.complete(const DeleteAccountFailed());
    await tester.pumpAndSettle();

    expect(_key('delete_account_error'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('delete_account_error'),
        matching: find.text(_errorText),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(_key('delete_account_confirm_field'))
          .controller!
          .text,
      'DELETE',
    );
    expect(_key('delete_account_spinner'), findsNothing);
    expect(submitButton(tester).onPressed, isNotNull);
  });

  testWidgets('invalid transfers refetch and re-default owners (scenario 11)', (
    tester,
  ) async {
    final repo = FakeAccountDeletionRepository(
      previews: [
        previewP(),
        previewP(
          alphaCandidates: [
            OwnerCandidate(
              userId: 14,
              name: 'Mia',
              avatarUrl: null,
              memberSince: DateTime(2026, 1, 2),
            ),
          ],
        ),
      ],
      result: Future.value(const DeleteAccountInvalidTransfers()),
    );
    await pumpDeleteAccountPage(tester, repo: repo);

    await typeConfirm(tester, 'DELETE');
    await tapSubmit(tester);
    await tester.pumpAndSettle();

    expect(repo.fetchCalls, 2);
    expect(
      find.descendant(
        of: _key('delete_account_owner_alpha'),
        matching: find.text('Mia'),
      ),
      findsOneWidget,
    );
    expect(_key('delete_account_error'), findsOneWidget);
  });

  testWidgets(
    'success toasts, then signs out the deleted account (scenario 12)',
    (tester) async {
      final repo = FakeAccountDeletionRepository(
        previews: [previewP()],
        result: Future.value(const DeleteAccountDeleted()),
      );
      final auth = await pumpDeleteAccountPage(tester, repo: repo);

      await typeConfirm(tester, 'DELETE');
      await tapSubmit(tester);
      await tester.pump();

      expect(auth.deletedSignOutCalls, 1);
      expect(
        auth.signOutCalls,
        0,
        reason: 'signOut() would 401 on push disable',
      );
      await tester.pump();
      final toast = _key('account_deleted_toast');
      expect(toast, findsOneWidget);
      expect(
        find.descendant(
          of: toast,
          matching: find.text('Your account was deleted.'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'success still toasts and signs out after the page was popped mid-request',
    (tester) async {
      final pending = Completer<DeleteAccountResult>();
      final repo = FakeAccountDeletionRepository(
        previews: [previewP()],
        result: pending.future,
      );
      final auth = await pumpDeleteAccountPage(
        tester,
        repo: repo,
        pushed: true,
      );

      await typeConfirm(tester, 'DELETE');
      await tapSubmit(tester);
      expect(_key('delete_account_spinner'), findsOneWidget);

      // Leave while the request is in flight; the page is disposed.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(_key('delete_account_page'), findsNothing);

      pending.complete(const DeleteAccountDeleted());
      await tester.pump();
      await tester.pump();

      expect(auth.deletedSignOutCalls, 1);
      expect(_key('account_deleted_toast'), findsOneWidget);
    },
  );

  testWidgets('a failed load offers Try again (scenario 13)', (tester) async {
    final repo = FakeAccountDeletionRepository(
      previews: [const ApiException('x'), previewP()],
    );
    await pumpDeleteAccountPage(tester, repo: repo);

    final error = _key('delete_account_load_error');
    expect(error, findsOneWidget);
    expect(
      find.descendant(
        of: error,
        matching: find.text(
          "Couldn't load. Check your connection and try again.",
        ),
      ),
      findsOneWidget,
    );
    expect(_key('delete_account_handoff_alpha'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(repo.fetchCalls, 2);
    expect(_key('delete_account_load_error'), findsNothing);
    expect(_key('delete_account_handoff_alpha'), findsOneWidget);
  });

  testWidgets('shows a spinner while the preview loads', (tester) async {
    final repo = _HangingPreviewRepository();
    await pumpDeleteAccountPage(tester, repo: repo, settle: false);

    expect(_key('delete_account_loading'), findsOneWidget);
    expect(
      find.descendant(
        of: _key('delete_account_loading'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
  });
}

/// A preview fetch that never answers — the loading state.
class _HangingPreviewRepository extends FakeAccountDeletionRepository {
  _HangingPreviewRepository() : super(previews: const []);

  @override
  Future<DeletionPreview> fetchPreview() => Completer<DeletionPreview>().future;
}
