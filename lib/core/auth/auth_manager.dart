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

  /// In-memory tokens for extra scopes, keyed by the sorted scope list.
  final Map<String, ScopedToken> _scoped = {};

  /// In-flight scoped-token requests, so parallel callers share one
  /// platform call (the Android plugin can only track one at a time).
  final Map<String, Future<String>> _scopedInFlight = {};
  Future<void>? _loading;
  Future<StoredCredentials>? _refreshing;

  /// Bumped whenever a session starts or ends, so a refresh that was in
  /// flight across a sign-out / sign-in never writes stale credentials back.
  int _generation = 0;

  /// Interactive Google sign-in. Throws [SignInCancelledException] if the user
  /// cancels, [AuthNetworkException] on network errors.
  Future<UserProfile> signIn() async {
    final credentials = await _backend.signIn();
    await _ensureLoaded();
    _generation++;
    _refreshing = null;
    _scoped.clear();
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
    await _endSession();
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

  /// Access token covering extra [scopes] (e.g. Colab), requested on demand.
  /// Throws [ScopeNotGrantedException] if not granted and not [interactive].
  /// [forceRefresh] discards the cached token (after a 401).
  Future<String> getScopedToken(
    List<String> scopes, {
    bool interactive = false,
    bool forceRefresh = false,
  }) async {
    await _ensureLoaded();
    if (_credentials == null) throw const NotSignedInException();
    final key = ([...scopes]..sort()).join(' ');
    final cached = _scoped[key];
    if (!forceRefresh &&
        cached != null &&
        _now().add(kTokenRefreshMargin).isBefore(cached.expiresAt)) {
      return cached.token;
    }
    final inFlight = _scopedInFlight[key];
    // Join a running request unless this one must prompt and that one won't.
    if (inFlight != null && !interactive) return inFlight;

    final generation = _generation;
    final request = () async {
      final fresh = await _backend.scopedToken(
        scopes,
        interactive: interactive,
        stale: forceRefresh ? cached?.token : null,
      );
      if (fresh == null) throw const ScopeNotGrantedException();
      if (generation == _generation) _scoped[key] = fresh;
      return fresh.token;
    }();
    _scopedInFlight[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_scopedInFlight[key], request)) _scopedInFlight.remove(key);
    }
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
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;

    final generation = _generation;
    final completer = Completer<StoredCredentials>();
    _refreshing = completer.future;

    () async {
      try {
        final refreshed = await _backend.refresh(current);
        if (generation != _generation) {
          // Signed out or switched accounts meanwhile: discard the result.
          completer.complete(_currentOrThrow());
          return;
        }
        await _save(refreshed);
        completer.complete(refreshed);
      } on AuthExpiredException catch (e, st) {
        if (generation == _generation) await _endSession();
        completer.completeError(e, st);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        if (identical(_refreshing, completer.future)) _refreshing = null;
      }
    }();

    return completer.future;
  }

  StoredCredentials _currentOrThrow() =>
      _credentials ?? (throw const NotSignedInException());

  Future<void> _ensureLoaded() {
    final loading = _loading ??= _storage.read().then(
      (c) => _credentials ??= c,
    );
    // Don't cache a failed read forever; retry on the next call.
    return loading.catchError((Object e) {
      if (identical(_loading, loading)) _loading = null;
      throw e;
    });
  }

  Future<void> _save(StoredCredentials credentials) async {
    _credentials = credentials;
    _loading = Future<void>.value();
    await _storage.write(credentials);
  }

  Future<void> _endSession() async {
    _generation++;
    _scoped.clear();
    _refreshing = null;
    _credentials = null;
    _loading = Future<void>.value();
    await _storage.clear();
  }
}
