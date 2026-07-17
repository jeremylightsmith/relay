// RLY-95: which board the Board tab shows. On-device only (decision 4) — the
// pick is per-install state, cleared on sign-out so it never outlives the
// session it was made in.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The last-viewed board slug, persisted across launches.
abstract class BoardPrefs {
  /// The stored slug, or null when nothing is stored — or the read failed.
  Future<String?> readLastBoardSlug();
  Future<void> writeLastBoardSlug(String slug);
  Future<void> clear();
}

/// The iOS Keychain, via flutter_secure_storage — the SecureSessionStore
/// pattern, failure posture included: every method swallows platform errors and
/// [readLastBoardSlug] returns null on failure, so a Keychain hiccup degrades to
/// "show the boards list", never a crash. That also keeps widget tests that do
/// not override [boardPrefsProvider] working: `flutter test` has no platform
/// channel.
class SecureBoardPrefs implements BoardPrefs {
  SecureBoardPrefs([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'relay_last_board_slug';
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> readLastBoardSlug() async {
    try {
      return await _storage.read(key: _key, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[board] slug read failed: $e');
      return null;
    }
  }

  @override
  Future<void> writeLastBoardSlug(String slug) async {
    try {
      await _storage.write(key: _key, value: slug, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[board] slug write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[board] slug clear failed: $e');
    }
  }
}

/// Tests.
class InMemoryBoardPrefs implements BoardPrefs {
  InMemoryBoardPrefs([this._slug]);

  String? _slug;

  /// The stored slug, for assertions.
  String? get slug => _slug;

  @override
  Future<String?> readLastBoardSlug() async => _slug;

  @override
  Future<void> writeLastBoardSlug(String slug) async {
    _slug = slug;
  }

  @override
  Future<void> clear() async {
    _slug = null;
  }
}

final boardPrefsProvider = Provider<BoardPrefs>((ref) => SecureBoardPrefs());
