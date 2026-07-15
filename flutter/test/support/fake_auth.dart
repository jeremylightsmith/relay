import 'package:relay_mobile/features/auth/auth_controller.dart';

/// [AuthController] with the network cut out: seeds a fixed [AuthState] and
/// records sign-in taps. No Dio, no Google, no cookies.
class FakeAuthController extends AuthController {
  FakeAuthController([this.initial = const AuthState()]);

  final AuthState initial;
  int signInCalls = 0;

  @override
  AuthState build() => initial;

  @override
  Future<void> signInWithGoogle() async {
    signInCalls++;
  }
}
