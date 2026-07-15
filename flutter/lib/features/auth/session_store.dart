// Where the native session credential lives. Persisting Phoenix's `_relay_key`
// cookie is what makes a cold-start push tap land on the card instead of the
// sign-in screen (RLY-86 §3).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The persisted `_relay_key` session cookie value.
abstract class SessionStore {
  /// The stored value, or null when nothing is stored — or the read failed.
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

/// The iOS Keychain, via flutter_secure_storage.
///
/// Accessibility is `first_unlock`: tapping a push implies the device has been
/// unlocked since boot, and this lets a restore run without waiting for another
/// unlock. Every method swallows platform errors and [read] returns null on
/// failure — a Keychain hiccup must degrade to "sign in again", never crash the
/// launch. That also keeps widget tests that do not override
/// [sessionStoreProvider] working: `flutter test` has no platform channel.
class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'relay_session_cookie';
  static const _iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock,
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[session] read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(String value) async {
    try {
      await _storage.write(key: _key, value: value, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[session] write failed: $e');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key, iOptions: _iosOptions);
    } catch (e) {
      debugPrint('[session] clear failed: $e');
    }
  }
}

/// Tests.
class InMemorySessionStore implements SessionStore {
  InMemorySessionStore([this._value]);

  String? _value;

  /// The stored value, for assertions.
  String? get value => _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async {
    _value = value;
  }

  @override
  Future<void> clear() async {
    _value = null;
  }
}

final sessionStoreProvider = Provider<SessionStore>(
  (ref) => SecureSessionStore(),
);
