import 'token_storage.dart';

/// Access token for extra scopes requested after sign-in (e.g. Colab).
class ScopedToken {
  const ScopedToken(this.token, this.expiresAt);
  final String token;
  final DateTime expiresAt;
}

/// Platform-specific OAuth 2.0 implementation used by [AuthManager].
///
/// * Android → `GoogleSignInAuthBackend` (Google Play Services / Credential
///   Manager via the `google_sign_in` plugin).
/// * Windows → `DesktopLoopbackAuthBackend` (system browser + loopback
///   redirect + PKCE). `google_sign_in` has no Windows implementation.
///
/// In both cases the user's password is entered only on Google's own pages;
/// the app never sees it (NFR-01).
abstract interface class AuthBackend {
  /// Interactive sign-in. Throws [SignInCancelledException] if the user backs
  /// out, or another `AuthException` on failure.
  Future<StoredCredentials> signIn();

  /// Silently obtains a fresh access token for an existing grant.
  /// Throws [AuthExpiredException] if the grant was revoked or has expired.
  Future<StoredCredentials> refresh(StoredCredentials current);

  /// Returns false if Google reports [accessToken] as invalid (e.g. access was
  /// revoked from the Google account settings). Throws
  /// [AuthNetworkException] when Google can't be reached.
  Future<bool> isAccessTokenValid(String accessToken);

  /// Access token that also covers [scopes] (incremental authorization).
  /// If they aren't granted yet: asks the user when [interactive], otherwise
  /// returns null. [stale] is a previous token to discard (after a 401).
  Future<ScopedToken?> scopedToken(
    List<String> scopes, {
    required bool interactive,
    String? stale,
  });

  /// Ends the session with the platform SDK / revokes the grant (best effort).
  Future<void> signOut(StoredCredentials? current);
}
