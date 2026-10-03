// RE106: the Sign in with Apple seam — the platform sheet behind a provider tests
// override, plus the nonce helpers.
//
// Nonce contract (one definition here, mirrored by AppleTokenValidator on the
// server): Apple is handed sha256(raw) as lowercase hex and embeds it in the
// identity token's `nonce` claim; the *raw* string goes to Relay, which recomputes
// the hash. A replayed token is useless without the raw nonce it was minted for.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Shows Apple's sheet, asking Apple to embed [hashedNonce] in the token.
typedef AppleCredentialRequest =
    Future<AuthorizationCredentialAppleID> Function(String hashedNonce);

final appleCredentialRequestProvider = Provider<AppleCredentialRequest>(
  (ref) =>
      (hashedNonce) => SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      ),
);

/// 32 cryptographically random bytes, base64url-encoded.
String generateRawNonce() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes);
}

/// Lowercase hex SHA-256 of [raw]'s UTF-8 bytes.
String sha256Hex(String raw) => sha256.convert(utf8.encode(raw)).toString();
