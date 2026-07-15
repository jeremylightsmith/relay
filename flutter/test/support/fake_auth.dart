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
