import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_backend.dart';
import '../core/auth/auth_config.dart';
import '../core/auth/auth_exceptions.dart';
import '../core/auth/auth_manager.dart';
import '../core/auth/desktop_loopback_auth_backend.dart';
import '../core/auth/google_sign_in_auth_backend.dart';
import '../core/auth/token_storage.dart';
import '../models/user_profile.dart';

final authConfigProvider = Provider<AuthConfig>(
  (ref) => const AuthConfig.fromEnvironment(),
);

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final authBackendProvider = Provider<AuthBackend>((ref) {
  final config = ref.watch(authConfigProvider);
  if (Platform.isAndroid) return GoogleSignInAuthBackend(config: config);
  // Windows (and Linux/macOS during development) use the browser flow.
  return DesktopLoopbackAuthBackend(config: config);
});

final authManagerProvider = Provider<AuthManager>(
  (ref) => AuthManager(
    backend: ref.watch(authBackendProvider),
    storage: ref.watch(tokenStorageProvider),
  ),
);

/// Current signed-in user (`null` = signed out). Errors from sign-in are
/// surfaced as `AsyncError`; a cancelled sign-in simply returns to signed-out.
final authControllerProvider =
    AsyncNotifierProvider<AuthController, UserProfile?>(AuthController.new);

class AuthController extends AsyncNotifier<UserProfile?> {
  AuthManager get _auth => ref.read(authManagerProvider);

  @override
  Future<UserProfile?> build() => _auth.restoreSession();

  Future<void> signIn() async {
    state = const AsyncLoading();
    try {
      state = AsyncData(await _auth.signIn());
    } on SignInCancelledException {
      state = const AsyncData(null);
    } on AuthException catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  Future<void> signOut() async {
    state = const AsyncLoading();
    await _auth.signOut();
    state = const AsyncData(null);
  }
}
