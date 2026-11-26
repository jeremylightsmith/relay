// RE509: the account-deletion repository — `GET /api/all/account/deletion`,
// `DELETE /api/all/account` — and the page's pure copy helpers.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay_mobile/api/api_client.dart';
import 'package:relay_mobile/features/settings/account_deletion.dart';

import '../../support/stub_adapter.dart';

const _previewJson = {
  'data': {
    'shared_boards': [
      {
        'slug': 'alpha',
        'name': 'Relay Engineering',
        'member_count': 4,
        'candidates': [
          {
            'user_id': 12,
            'name': 'Ana Ruiz',
            'avatar_url': null,
            'member_since': '2026-03-01',
          },
          {
            'user_id': 13,
            'name': 'Kenji Ota',
            'avatar_url': 'https://lh3.example.com/k.png',
            'member_since': '2026-06-15',
          },
        ],
      },
    ],
    'solo_boards': [
      {'slug': 'side', 'name': 'Side project'},
    ],
    'plan_ends': true,
    'runners': ['macbook-pro'],
    'apple_reauth_required': true,
  },
};

(AccountDeletionRepository, StubAdapter) _repo(StubAdapter adapter) {
  final client = ApiClient(tokenReader: () => 't');
  client.dio.httpClientAdapter = adapter;
  return (AccountDeletionRepository(client), adapter);
}

Map<String, dynamic> _error(String code) => {
  'error': {'code': code, 'message': 'm'},
};

void main() {
  group('fetchPreview', () {
    test('GETs the preview and parses every field (scenario 14)', () async {
      final (repo, adapter) = _repo(StubAdapter(body: _previewJson));

      final preview = await repo.fetchPreview();

      expect(adapter.requests.single.method, 'GET');
      expect(adapter.requests.single.path, '/api/all/account/deletion');
      final board = preview.sharedBoards.single;
      expect(board.slug, 'alpha');
      expect(board.name, 'Relay Engineering');
      expect(board.memberCount, 4);
      expect(board.candidates.map((c) => c.userId), [12, 13]);
      expect(board.candidates.first.name, 'Ana Ruiz');
      expect(board.candidates.first.avatarUrl, isNull);
      expect(board.candidates.first.memberSince, DateTime(2026, 3, 1));
      expect(board.candidates.last.avatarUrl, 'https://lh3.example.com/k.png');
      expect(preview.soloBoards.single.slug, 'side');
      expect(preview.soloBoards.single.name, 'Side project');
      expect(preview.planEnds, isTrue);
      expect(preview.runners, ['macbook-pro']);
      expect(preview.appleReauthRequired, isTrue);
    });

    test('a non-200 throws ApiException', () async {
      final (repo, _) = _repo(
        StubAdapter(statusCode: 401, body: _error('unauthorized')),
      );

      expect(repo.fetchPreview(), throwsA(isA<ApiException>()));
    });
  });

  group('deleteAccount (scenario 15)', () {
    test(
      'a 204 is DeleteAccountDeleted, sent as DELETE with the full body',
      () async {
        final (repo, adapter) = _repo(StubAdapter(statusCode: 204));

        final result = await repo.deleteAccount(
          transfers: {'alpha': 12},
          appleAuthorizationCode: 'c',
        );

        expect(result, isA<DeleteAccountDeleted>());
        final req = adapter.requests.single;
        expect(req.method, 'DELETE');
        expect(req.path, '/api/all/account');
        expect(req.data, {
          'confirm': 'DELETE',
          'transfers': {'alpha': 12},
          'apple_authorization_code': 'c',
        });
      },
    );

    test('422 invalid_transfers is DeleteAccountInvalidTransfers', () async {
      final (repo, _) = _repo(
        StubAdapter(statusCode: 422, body: _error('invalid_transfers')),
      );

      final result = await repo.deleteAccount(transfers: const {});

      expect(result, isA<DeleteAccountInvalidTransfers>());
    });

    test('422 apple_reauth_required is DeleteAccountFailed', () async {
      final (repo, _) = _repo(
        StubAdapter(statusCode: 422, body: _error('apple_reauth_required')),
      );

      final result = await repo.deleteAccount(transfers: const {});

      expect(result, isA<DeleteAccountFailed>());
    });

    test('403 apple_mismatch is DeleteAccountFailed', () async {
      final (repo, _) = _repo(
        StubAdapter(statusCode: 403, body: _error('apple_mismatch')),
      );

      final result = await repo.deleteAccount(transfers: const {});

      expect(result, isA<DeleteAccountFailed>());
    });

    test(
      '502 apple_revoke_failed (thrown by dio) is DeleteAccountFailed',
      () async {
        final (repo, _) = _repo(
          StubAdapter(statusCode: 502, body: _error('apple_revoke_failed')),
        );

        final result = await repo.deleteAccount(transfers: const {});

        expect(result, isA<DeleteAccountFailed>());
      },
    );

    test('a transport failure is DeleteAccountFailed', () async {
      final (repo, _) = _repo(
        StubAdapter(
          failure: DioException(
            requestOptions: RequestOptions(path: '/api/all/account'),
            type: DioExceptionType.connectionError,
          ),
        ),
      );

      final result = await repo.deleteAccount(transfers: const {});

      expect(result, isA<DeleteAccountFailed>());
    });

    test('a null Apple code leaves the key out of the body', () async {
      final (repo, adapter) = _repo(StubAdapter(statusCode: 204));

      await repo.deleteAccount(transfers: {'alpha': 12});

      final data = adapter.requests.single.data as Map;
      expect(data.containsKey('apple_authorization_code'), isFalse);
      expect(data, {
        'confirm': 'DELETE',
        'transfers': {'alpha': 12},
      });
    });
  });

  group('copy helpers (scenario 16)', () {
    test('memberSinceLabel names the English three-letter month', () {
      expect(memberSinceLabel(DateTime(2026, 3, 1)), 'member since Mar 2026');
      expect(memberSinceLabel(DateTime(2026, 6, 15)), 'member since Jun 2026');
      expect(memberSinceLabel(DateTime(2025, 12, 31)), 'member since Dec 2025');
    });

    test('runnersLine is singular for one runner', () {
      expect(runnersLine(['a']), '1 runner you started will stop: a');
    });

    test('runnersLine is plural and comma-joined for several', () {
      expect(runnersLine(['a', 'b']), '2 runners you started will stop: a, b');
    });
  });
}
