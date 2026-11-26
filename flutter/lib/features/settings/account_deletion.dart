// RE509: deleting your account from Settings — the server's preview of what a
// deletion would do (`GET /api/all/account/deletion`), the deletion itself
// (`DELETE /api/all/account`), and the copy helpers the confirm page shares.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';

/// What deleting the account would do, as the server computed it: who takes
/// over each shared board, what is deleted with the account, and whether Apple
/// must re-authorize first.
class DeletionPreview {
  const DeletionPreview({
    required this.sharedBoards,
    required this.soloBoards,
    required this.planEnds,
    required this.runners,
    required this.appleReauthRequired,
  });

  factory DeletionPreview.fromJson(Map<String, dynamic> json) =>
      DeletionPreview(
        sharedBoards: _list(json['shared_boards'], SharedBoard.fromJson),
        soloBoards: _list(json['solo_boards'], SoloBoard.fromJson),
        planEnds: json['plan_ends'] as bool? ?? false,
        runners: ((json['runners'] as List?) ?? const []).cast<String>().toList(
          growable: false,
        ),
        appleReauthRequired: json['apple_reauth_required'] as bool? ?? false,
      );

  final List<SharedBoard> sharedBoards;
  final List<SoloBoard> soloBoards;
  final bool planEnds;
  final List<String> runners;
  final bool appleReauthRequired;
}

/// A board the person owns that others use; it passes to one of [candidates].
class SharedBoard {
  const SharedBoard({
    required this.slug,
    required this.name,
    required this.memberCount,
    required this.candidates,
  });

  factory SharedBoard.fromJson(Map<String, dynamic> json) => SharedBoard(
    slug: json['slug'] as String,
    name: json['name'] as String,
    memberCount: json['member_count'] as int,
    candidates: _list(json['candidates'], OwnerCandidate.fromJson),
  );

  final String slug;
  final String name;
  final int memberCount;

  /// Server order: longest on the board first, so `first` is the default owner.
  final List<OwnerCandidate> candidates;
}

/// A member who could take over a [SharedBoard].
class OwnerCandidate {
  const OwnerCandidate({
    required this.userId,
    required this.name,
    required this.avatarUrl,
    required this.memberSince,
  });

  factory OwnerCandidate.fromJson(Map<String, dynamic> json) => OwnerCandidate(
    userId: json['user_id'] as int,
    name: json['name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
    memberSince: _date(json['member_since'] as String),
  );

  final int userId;
  final String? name;
  final String? avatarUrl;
  final DateTime memberSince;
}

/// A board nobody else uses; it is deleted with the account.
class SoloBoard {
  const SoloBoard({required this.slug, required this.name});

  factory SoloBoard.fromJson(Map<String, dynamic> json) =>
      SoloBoard(slug: json['slug'] as String, name: json['name'] as String);

  final String slug;
  final String name;
}

/// How a `DELETE /api/all/account` went.
sealed class DeleteAccountResult {
  const DeleteAccountResult();
}

/// 204: the account is gone.
class DeleteAccountDeleted extends DeleteAccountResult {
  const DeleteAccountDeleted();
}

/// 422 `invalid_transfers`: the boards or their members changed since the
/// preview. Nothing was deleted; refetch and ask again.
class DeleteAccountInvalidTransfers extends DeleteAccountResult {
  const DeleteAccountInvalidTransfers();
}

/// Anything else — another 4xx, a 5xx, or no answer. Nothing was deleted.
class DeleteAccountFailed extends DeleteAccountResult {
  const DeleteAccountFailed();
}

/// HTTP + parsing for account deletion; the page owns the flow.
class AccountDeletionRepository {
  AccountDeletionRepository(this._client);

  final ApiClient _client;

  /// Throws [ApiException] on a non-200 or a transport failure.
  Future<DeletionPreview> fetchPreview() async {
    final body = await _client.getJson('/api/all/account/deletion');
    return DeletionPreview.fromJson(
      ((body as Map)['data'] as Map).cast<String, dynamic>(),
    );
  }

  /// Never throws. [transfers] maps each shared board's slug to its new
  /// owner's user id; [appleAuthorizationCode] is sent only when given.
  Future<DeleteAccountResult> deleteAccount({
    required Map<String, int> transfers,
    String? appleAuthorizationCode,
  }) async {
    final ApiResponse resp;
    try {
      resp = await _client.deleteJson('/api/all/account', {
        'confirm': 'DELETE',
        'transfers': transfers,
        'apple_authorization_code': ?appleAuthorizationCode,
      });
    } on ApiException {
      // Transport failures, and 5xx (ApiClient's validateStatus throws them).
      return const DeleteAccountFailed();
    }
    return switch (resp.statusCode) {
      204 => const DeleteAccountDeleted(),
      422 when _errorCode(resp.data) == 'invalid_transfers' =>
        const DeleteAccountInvalidTransfers(),
      _ => const DeleteAccountFailed(),
    };
  }

  String? _errorCode(dynamic body) {
    if (body is Map && body['error'] is Map) {
      return (body['error'] as Map)['code'] as String?;
    }
    return null;
  }
}

final accountDeletionRepositoryProvider = Provider<AccountDeletionRepository>(
  (ref) => AccountDeletionRepository(ref.watch(apiClientProvider)),
);

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "member since Mar 2026" — English three-letter months, no intl.
String memberSinceLabel(DateTime d) =>
    'member since ${_months[d.month - 1]} ${d.year}';

/// "1 runner you started will stop: a" / "2 runners you started will stop: a, b".
String runnersLine(List<String> names) {
  final noun = names.length == 1 ? 'runner' : 'runners';
  return '${names.length} $noun you started will stop: ${names.join(', ')}';
}

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    ((raw as List?) ?? const [])
        .map((e) => parse((e as Map).cast<String, dynamic>()))
        .toList(growable: false);

/// A `YYYY-MM-DD` date as a local calendar date (no time, no zone shift).
DateTime _date(String iso) {
  final parsed = DateTime.parse(iso);
  return DateTime(parsed.year, parsed.month, parsed.day);
}
