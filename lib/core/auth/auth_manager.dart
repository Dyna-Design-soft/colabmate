import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/user_profile.dart';
import 'auth_backend.dart';
import 'auth_config.dart';
import 'auth_exceptions.dart';
import 'token_storage.dart';

/// Manages the Google OAuth 2.0 login lifecycle (spec §4.1). Every other module
/// gets its access token from [getAccessToken].
///
/// Tokens are persisted with [TokenStorage] (Keystore / Credential Manager)
/// and refreshed silently when they are within [kTokenRefreshMargin] of
/// expiring.
class AuthManager {
  AuthManager({
    required this._backend,
    TokenStorage? storage,
    DateTime Function()? clock,
  }) : _storage = storage ?? TokenStorage(),
       _now = clock ?? DateTime.now;

  final AuthBackend _backend;
  final TokenStorage _storage;
  final DateTime Function() _now;

  StoredCredentials? _credentials;
  Future<void>? _loading;
  Future<StoredCredentials>? _refreshing;

  /// Interactive Google sign-in. Throws [SignInCancelledException] if the user
  /// cancels, [AuthNetworkException] on network errors.
  Future<UserProfile> signIn() async {
    final credentials = await _backend.signIn();
    await _save(credentials);
    return credentials.profile;
  }

  /// Signs out and removes stored tokens.
  Future<void> signOut() async {
    await _ensureLoaded();
    final current = _credentials;
    try {
      await _backend.signOut(current);
    } catch (e) {
      debugPrint('AuthManager: backend sign-out failed ($e); clearing anyway');
    }
    await _clear();
  }

  /// Returns a valid access token, refreshing it first if it is about to
  /// expire. Throws [NotSignedInException] if nobody is signed in and
  /// [AuthExpiredException] if the grant can no longer be refreshed (the
  /// stored session is then cleared).
  Future<String> getAccessToken() async {
    await _ensureLoaded();
    final current = _credentials;
    if (current == null) throw const NotSignedInException();
    if (!current.isExpired(_now(), margin: kTokenRefreshMargin)) {
      return current.accessToken;
    }
    return (await _refresh(current)).accessToken;
  }

  /// Forces a token refresh, e.g. after an API call returned 401.
  Future<String> refreshAccessToken() async {
    await _ensureLoaded();
    final current = _credentials;
    if (current == null) throw const NotSignedInException();
    return (await _refresh(current)).accessToken;
  }

  Future<bool> isSignedIn() async {
    await _ensureLoaded();
    return _credentials != null;
  }

  /// Throws [NotSignedInException] if nobody is signed in.
  Future<UserProfile> getUserProfile() async {
    await _ensureLoaded();
    final current = _credentials;
    if (current == null) throw const NotSignedInException();
    return current.profile;
  }

  /// Called at app start. Returns the stored user if the session is still
  /// usable, or null if the user must sign in.
  ///
  /// When online, the token is verified with Google so a grant revoked from
  /// the Google account settings is detected immediately (test A6). When
  /// offline, the stored session is kept so cached notebooks stay usable.
  Future<UserProfile?> restoreSession() async {
    await _ensureLoaded();
    final current = _credentials;
    if (current == null) return null;
    try {
      final expiring = current.isExpired(_now(), margin: kTokenRefreshMargin);
      if (expiring || !await _backend.isAccessTokenValid(current.accessToken)) {
        await _refresh(current);
      }
      return _credentials?.profile;
    } on AuthExpiredException {
      return null;
    } on AuthNetworkException {
      return current.profile;
    }
  }

  Future<StoredCredentials> _refresh(StoredCredentials current) {
    // Concurrent callers share one in-flight refresh.
    return _refreshing ??= () async {
      try {
        final refreshed = await _backend.refresh(current);
        await _save(refreshed);
        return refreshed;
      } on AuthExpiredException {
        await _clear();
        rethrow;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<void> _ensureLoaded() =>
      _loading ??= _storage.read().then((c) => _credentials ??= c);

  Future<void> _save(StoredCredentials credentials) async {
    _credentials = credentials;
    _loading ??= Future<void>.value();
    await _storage.write(credentials);
  }

  Future<void> _clear() async {
    _credentials = null;
    _loading ??= Future<void>.value();
    await _storage.clear();
  }
}
