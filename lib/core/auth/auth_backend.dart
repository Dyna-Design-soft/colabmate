import 'token_storage.dart';

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

  /// Ends the session with the platform SDK / revokes the grant (best effort).
  Future<void> signOut(StoredCredentials? current);
}
