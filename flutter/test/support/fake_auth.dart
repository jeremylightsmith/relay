import 'package:relay_mobile/features/auth/auth_controller.dart';

/// [AuthController] with the network cut out: seeds a fixed [AuthState] and
/// records sign-in taps. No Dio, no Google, no cookies.
///
/// The default seed is `signedOut`, not the real controller's `restoring`: a fake
/// never restores, so `restoring` would park the router on the splash forever.
class FakeAuthController extends AuthController {
  FakeAuthController([
    this.initial = const AuthState(status: AuthStatus.signedOut),
  ]);

  final AuthState initial;
  int signInCalls = 0;

  @override
  AuthState build() => initial;

  @override
  Future<void> signInWithGoogle() async {
    signInCalls++;
  }
}

/// An [AuthController] whose lifecycle the test drives by hand: it starts
/// `restoring` — like the real one — and lands wherever [resolve] says.
class ScriptedAuthController extends AuthController {
  @override
  AuthState build() => const AuthState();

  void resolve(AuthState next) => state = next;

  @override
  Future<void> signInWithGoogle() async {
    // Two steps, like the real flow: `signingIn` is what tells main.dart this was
    // an *interactive* sign-in and not a restore.
    state = const AuthState(status: AuthStatus.signingIn);
    state = const AuthState(
      status: AuthStatus.signedIn,
      user: {'email': 'dana@acme.co'},
    );
  }
}
