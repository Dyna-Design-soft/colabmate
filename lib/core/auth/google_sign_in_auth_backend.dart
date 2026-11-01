import 'dart:async';

import 'package:google_sign_in/google_sign_in.dart';

import '../../models/user_profile.dart';
import 'auth_backend.dart';
import 'auth_config.dart';
import 'auth_exceptions.dart';
import 'google_oauth_api.dart';
import 'token_storage.dart';

/// Android sign-in through the `google_sign_in` plugin (Credential Manager +
/// Google Play Services authorization). Play Services holds the long-lived
/// grant, so no refresh token is stored by the app.
class GoogleSignInAuthBackend implements AuthBackend {
  GoogleSignInAuthBackend({
    required this._config,
    GoogleOAuthApi? api,
    DateTime Function()? clock,
  }) : _api = api ?? GoogleOAuthApi(),
       _now = clock ?? DateTime.now;

  final AuthConfig _config;
  final GoogleOAuthApi _api;
  final DateTime Function() _now;
  Future<void>? _init;

  /// Play Services doesn't report the token's lifetime (and may hand back a
  /// cached, partly used token), so it is looked up with Google's tokeninfo.
  /// If that lookup fails for network reasons, assume this conservative
  /// lifetime so the token is refreshed early rather than late.
  static const Duration _fallbackLifetime = Duration(minutes: 10);

  /// Upper bound for non-interactive Play Services calls, so a call that
  /// never answers shows an error instead of an endless spinner.
  static const Duration _platformTimeout = Duration(seconds: 30);

  GoogleSignIn get _gsi => GoogleSignIn.instance;

  Future<void> _ensureInitialized() async {
    if (_config.androidServerClientId.isEmpty) {
      throw const AuthConfigException(
        'GOOGLE_SERVER_CLIENT_ID is not set. See README "Google Cloud setup".',
      );
    }
    final init = _init ??= _gsi.initialize(
      serverClientId: _config.androidServerClientId,
    );
    try {
      await init;
    } catch (_) {
      // Don't cache a failed initialize (e.g. Play Services updating).
      if (identical(_init, init)) _init = null;
      rethrow;
    }
  }

  @override
  Future<StoredCredentials> signIn() => _guard(() async {
    await _ensureInitialized();
    final account = await _gsi.authenticate(scopeHint: kGoogleScopes);
    final client = account.authorizationClient;
    final authz =
        await client.authorizationForScopes(kGoogleScopes) ??
        await client.authorizeScopes(kGoogleScopes);
    return await _credentials(account, authz.accessToken);
  });

  @override
  Future<StoredCredentials> refresh(StoredCredentials current) =>
      _guard(() async {
        await _ensureInitialized();
        final account = await _gsi.attemptLightweightAuthentication();
        if (account == null) throw const AuthExpiredException();
        final client = account.authorizationClient;
        // Drop the cached token so Play Services mints a fresh one.
        await client.clearAuthorizationToken(accessToken: current.accessToken);
        final authz = await client.authorizationForScopes(kGoogleScopes);
        if (authz == null) throw const AuthExpiredException();
        return await _credentials(account, authz.accessToken);
      });

  @override
  Future<ScopedToken?> scopedToken(
    List<String> scopes, {
    required bool interactive,
    String? stale,
  }) => _guard(() async {
    await _ensureInitialized();
    // Authorization only — no need to re-run the sign-in (Credential
    // Manager) step, which can show UI and only handles one call at a time.
    final client = _gsi.authorizationClient;
    if (stale != null) {
      await client
          .clearAuthorizationToken(accessToken: stale)
          .timeout(_platformTimeout);
    }
    final authz =
        await client.authorizationForScopes(scopes).timeout(_platformTimeout) ??
        (interactive
            // The user may take a while on Google's consent screen.
            ? await client
                  .authorizeScopes(scopes)
                  .timeout(const Duration(minutes: 5))
            : null);
    if (authz == null) return null;
    Duration lifetime;
    try {
      lifetime = await _api.tokenLifetime(authz.accessToken) ?? Duration.zero;
    } on AuthNetworkException {
      lifetime = _fallbackLifetime;
    }
    return ScopedToken(authz.accessToken, _now().add(lifetime));
  });

  @override
  Future<bool> isAccessTokenValid(String accessToken) =>
      _api.isAccessTokenValid(accessToken);

  @override
  Future<void> signOut(StoredCredentials? current) async {
    try {
      await _ensureInitialized();
      await _gsi.signOut();
    } on GoogleSignInException {
      // Local credentials are cleared by AuthManager regardless.
    }
  }

  Future<StoredCredentials> _credentials(
    GoogleSignInAccount account,
    String token,
  ) async {
    Duration lifetime;
    try {
      // null = already invalid → zero lifetime forces a refresh on first use.
      lifetime = await _api.tokenLifetime(token) ?? Duration.zero;
    } on AuthNetworkException {
      lifetime = _fallbackLifetime;
    }
    return StoredCredentials(
      accessToken: token,
      expiresAt: _now().add(lifetime),
      profile: UserProfile(
        id: account.id,
        email: account.email,
        name: account.displayName,
        photoUrl: account.photoUrl,
      ),
    );
  }

  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on TimeoutException {
      throw const AuthUnknownException(
        'Google Play services did not respond. Please try again.',
      );
    } on GoogleSignInException catch (e) {
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
        case GoogleSignInExceptionCode.interrupted:
          throw const SignInCancelledException();
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          throw AuthConfigException(
            'Google Sign-In configuration error: ${e.description}',
          );
        default:
          throw AuthUnknownException(e.description ?? e.code.name);
      }
    }
  }
}
