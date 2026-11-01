import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:colabmate/core/auth/auth_backend.dart';
import 'package:colabmate/core/auth/auth_config.dart';
import 'package:colabmate/core/auth/auth_exceptions.dart';
import 'package:colabmate/core/auth/auth_manager.dart';
import 'package:colabmate/core/auth/desktop_loopback_auth_backend.dart';
import 'package:colabmate/core/auth/google_oauth_api.dart';
import 'package:colabmate/core/auth/token_storage.dart';
import 'package:colabmate/models/user_profile.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class MemoryStore implements SecureKeyValueStore {
  final Map<String, String> data = {};
  Object? readError;
  @override
  Future<String?> read(String key) async {
    if (readError != null) throw readError!;
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

const _user = UserProfile(
  id: '42',
  email: 'k@example.com',
  name: 'Karthikeyan S',
  photoUrl: 'p',
);

class FakeBackend implements AuthBackend {
  FakeBackend(this.now);
  final DateTime Function() now;

  int signInCalls = 0, refreshCalls = 0, signOutCalls = 0;
  Object? signInError;
  Object? signOutError;
  Object? refreshError;
  bool tokenValid = true;
  Object? validateError;
  Completer<void>? refreshGate;

  /// Scopes the user has granted beyond sign-in.
  bool extraGranted = false;
  bool userAcceptsPrompt = true;
  int scopedCalls = 0;
  Completer<void>? scopedGate;
  final List<String?> staleTokens = [];

  @override
  Future<ScopedToken?> scopedToken(
    List<String> scopes, {
    required bool interactive,
    String? stale,
  }) async {
    scopedCalls++;
    staleTokens.add(stale);
    await scopedGate?.future;
    if (!extraGranted && interactive && userAcceptsPrompt) extraGranted = true;
    if (!extraGranted) return null;
    return ScopedToken(
      'scoped-$scopedCalls',
      now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<StoredCredentials> signIn() async {
    signInCalls++;
    if (signInError != null) throw signInError!;
    return StoredCredentials(
      accessToken: 'token-0',
      expiresAt: now().add(const Duration(hours: 1)),
      refreshToken: 'refresh',
      profile: _user,
    );
  }

  @override
  Future<StoredCredentials> refresh(StoredCredentials current) async {
    refreshCalls++;
    await refreshGate?.future;
    if (refreshError != null) throw refreshError!;
    return current.copyWith(
      accessToken: 'token-$refreshCalls',
      expiresAt: now().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<bool> isAccessTokenValid(String accessToken) async {
    if (validateError != null) throw validateError!;
    return tokenValid;
  }

  @override
  Future<void> signOut(StoredCredentials? current) async {
    signOutCalls++;
    if (signOutError != null) throw signOutError!;
  }
}

void main() {
  late DateTime now;
  late MemoryStore store;
  late FakeBackend backend;

  AuthManager newManager() => AuthManager(
    backend: backend,
    storage: TokenStorage(store),
    clock: () => now,
  );

  setUp(() {
    now = DateTime.utc(2026, 11, 1, 10);
    store = MemoryStore();
    backend = FakeBackend(() => now);
  });

  group('AuthManager', () {
    test('starts signed out', () async {
      final auth = newManager();
      expect(await auth.isSignedIn(), isFalse);
      expect(auth.getAccessToken(), throwsA(isA<NotSignedInException>()));
      expect(auth.getUserProfile(), throwsA(isA<NotSignedInException>()));
      expect(await auth.restoreSession(), isNull);
    });

    test('signIn returns profile and stores credentials securely', () async {
      final auth = newManager();
      expect(await auth.signIn(), _user);
      expect(await auth.isSignedIn(), isTrue);
      expect(await auth.getUserProfile(), _user);
      expect(await auth.getAccessToken(), 'token-0');
      expect(store.data, hasLength(1));
    });

    test('session persists across app restarts (A3)', () async {
      await newManager().signIn();
      final restarted = newManager();
      expect(await restarted.restoreSession(), _user);
      expect(await restarted.getAccessToken(), 'token-0');
      expect(backend.refreshCalls, 0);
    });

    test(
      'signOut clears stored credentials (A4) and sign-in works again (A5)',
      () async {
        final auth = newManager();
        await auth.signIn();
        await auth.signOut();
        expect(backend.signOutCalls, 1);
        expect(await auth.isSignedIn(), isFalse);
        expect(store.data, isEmpty);
        expect(await newManager().isSignedIn(), isFalse);

        expect(await auth.signIn(), _user);
        expect(await auth.isSignedIn(), isTrue);
      },
    );

    test('signOut still clears locally if backend sign-out fails', () async {
      backend.signOutError = const AuthNetworkException();
      final auth = newManager();
      await auth.signIn();
      await auth.signOut();
      expect(store.data, isEmpty);
    });

    test('cancelled sign-in propagates and leaves user signed out', () async {
      backend.signInError = const SignInCancelledException();
      final auth = newManager();
      await expectLater(
        auth.signIn(),
        throwsA(isA<SignInCancelledException>()),
      );
      expect(await auth.isSignedIn(), isFalse);
    });

    test('getAccessToken auto-refreshes near expiry', () async {
      final auth = newManager();
      await auth.signIn();
      now = now.add(const Duration(minutes: 54)); // 6 min left: still fresh
      expect(await auth.getAccessToken(), 'token-0');
      now = now.add(const Duration(minutes: 2)); // 4 min left: refresh
      expect(await auth.getAccessToken(), 'token-1');
      expect(backend.refreshCalls, 1);
      // Refreshed token persisted.
      expect(await newManager().getAccessToken(), 'token-1');
    });

    test('concurrent getAccessToken calls share one refresh', () async {
      final auth = newManager();
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      backend.refreshGate = Completer<void>();
      final a = auth.getAccessToken();
      final b = auth.getAccessToken();
      backend.refreshGate!.complete();
      expect(await Future.wait([a, b]), ['token-1', 'token-1']);
      expect(backend.refreshCalls, 1);
    });

    test('expired grant clears session and throws AuthExpired', () async {
      final auth = newManager();
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      backend.refreshError = const AuthExpiredException();
      await expectLater(
        auth.getAccessToken(),
        throwsA(isA<AuthExpiredException>()),
      );
      expect(await auth.isSignedIn(), isFalse);
      expect(store.data, isEmpty);
    });

    test(
      'restoreSession detects access revoked in Google settings (A6)',
      () async {
        await newManager().signIn();
        backend
          ..tokenValid = false
          ..refreshError = const AuthExpiredException();
        final restarted = newManager();
        expect(await restarted.restoreSession(), isNull);
        expect(await restarted.isSignedIn(), isFalse);
      },
    );

    test('restoreSession keeps session when offline', () async {
      await newManager().signIn();
      backend.validateError = const AuthNetworkException();
      final restarted = newManager();
      expect(await restarted.restoreSession(), _user);
      expect(await restarted.isSignedIn(), isTrue);
    });

    test('refresh finishing after signOut does not restore session', () async {
      final auth = newManager();
      await auth.signIn();
      now = now.add(const Duration(hours: 2));
      backend.refreshGate = Completer<void>();
      final pending = auth.getAccessToken();
      await auth.signOut();
      backend.refreshGate!.complete();
      await expectLater(pending, throwsA(isA<NotSignedInException>()));
      expect(await auth.isSignedIn(), isFalse);
      expect(store.data, isEmpty);
      expect(await newManager().isSignedIn(), isFalse);
    });

    test(
      'refresh finishing after a new signIn keeps the new session',
      () async {
        final auth = newManager();
        await auth.signIn();
        now = now.add(const Duration(hours: 2));
        backend.refreshGate = Completer<void>();
        final pending = auth.getAccessToken();
        await auth.signIn(); // new session: token-0, fresh expiry
        backend.refreshGate!.complete();
        expect(await pending, 'token-0');
        expect(await newManager().getAccessToken(), 'token-0');
      },
    );

    test('failed secure-storage read is not cached forever', () async {
      store.readError = Exception('keystore unavailable');
      final auth = newManager();
      // TokenStorage treats an unreadable store as "no credentials".
      expect(await auth.isSignedIn(), isFalse);
      store.readError = null;
      expect(await auth.signIn(), _user);
      expect(await auth.isSignedIn(), isTrue);
    });

    group('extra scopes (Colab)', () {
      const colab = ['https://www.googleapis.com/auth/colaboratory'];

      test(
        'not granted + not interactive → ScopeNotGrantedException',
        () async {
          final auth = newManager();
          await auth.signIn();
          await expectLater(
            auth.getScopedToken(colab),
            throwsA(isA<ScopeNotGrantedException>()),
          );
        },
      );

      test('interactive grant, then cached until near expiry', () async {
        final auth = newManager();
        await auth.signIn();
        expect(await auth.getScopedToken(colab, interactive: true), 'scoped-1');
        expect(await auth.getScopedToken(colab), 'scoped-1');
        expect(backend.scopedCalls, 1);
        now = now.add(const Duration(minutes: 56));
        expect(await auth.getScopedToken(colab), 'scoped-2');
      });

      test('parallel requests share one platform call', () async {
        final auth = newManager();
        await auth.signIn();
        await auth.getScopedToken(colab, interactive: true);
        now = now.add(const Duration(hours: 2)); // cached token expired
        backend.scopedGate = Completer<void>();
        final calls = [
          auth.getScopedToken(colab),
          auth.getScopedToken(colab),
          auth.getScopedToken(colab),
        ];
        backend.scopedGate!.complete();
        expect((await Future.wait(calls)).toSet(), {'scoped-2'});
        expect(backend.scopedCalls, 2, reason: '1 grant + 1 shared refresh');
      });

      test('forceRefresh passes the stale token to discard', () async {
        final auth = newManager();
        await auth.signIn();
        await auth.getScopedToken(colab, interactive: true);
        expect(
          await auth.getScopedToken(colab, forceRefresh: true),
          'scoped-2',
        );
        expect(backend.staleTokens.last, 'scoped-1');
      });

      test('user declining the prompt → ScopeNotGrantedException', () async {
        backend.userAcceptsPrompt = false;
        final auth = newManager();
        await auth.signIn();
        await expectLater(
          auth.getScopedToken(colab, interactive: true),
          throwsA(isA<ScopeNotGrantedException>()),
        );
      });

      test('requires sign-in, and sign-out drops cached tokens', () async {
        final auth = newManager();
        await expectLater(
          auth.getScopedToken(colab),
          throwsA(isA<NotSignedInException>()),
        );
        await auth.signIn();
        await auth.getScopedToken(colab, interactive: true);
        await auth.signOut();
        await auth.signIn();
        await auth.getScopedToken(colab);
        expect(backend.scopedCalls, 2, reason: 'cache cleared on sign-out');
      });
    });

    test('unreadable stored credentials are discarded', () async {
      store.data['colabmate.credentials.v1'] = '{not json';
      final auth = newManager();
      expect(await auth.isSignedIn(), isFalse);
      expect(store.data, isEmpty);
    });
  });

  group('DesktopLoopbackAuthBackend', () {
    const config = AuthConfig(
      androidServerClientId: '',
      desktopClientId: 'client-id',
      desktopClientSecret: 'secret',
    );

    test('full loopback flow with PKCE + state', () async {
      final google = _FakeGoogle();
      late Uri opened;
      final backend = DesktopLoopbackAuthBackend(
        config: config,
        api: GoogleOAuthApi(google.dio),
        clock: () => now,
        openUrl: (url) async {
          opened = url;
          // Simulate the browser following Google's redirect.
          final q = url.queryParameters;
          unawaited(
            HttpClient()
                .getUrl(
                  Uri.parse(q['redirect_uri']!).replace(
                    queryParameters: {'code': 'auth-code', 'state': q['state']},
                  ),
                )
                .then((r) => r.close())
                .then((r) => r.drain<void>()),
          );
          return true;
        },
      );

      final creds = await backend.signIn();

      final q = opened.queryParameters;
      expect(opened.host, 'accounts.google.com');
      expect(q['client_id'], 'client-id');
      expect(q['code_challenge_method'], 'S256');
      expect(q['access_type'], 'offline');
      expect(q['redirect_uri'], startsWith('http://127.0.0.1:'));
      expect(q['scope'], contains('https://www.googleapis.com/auth/drive'));

      final tokenReq = google.requests.single;
      expect(tokenReq['grant_type'], 'authorization_code');
      expect(tokenReq['code'], 'auth-code');
      expect(tokenReq['redirect_uri'], q['redirect_uri']);
      // PKCE: challenge = BASE64URL(SHA256(verifier)) without padding.
      final verifier = tokenReq['code_verifier']!;
      expect(verifier, hasLength(64));
      expect(
        q['code_challenge'],
        base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', ''),
      );
      expect(q['code_challenge'], isNot(contains('=')));

      expect(creds.accessToken, 'access-1');
      expect(creds.refreshToken, 'refresh-1');
      expect(creds.expiresAt, now.add(const Duration(seconds: 3599)));
      expect(creds.profile.email, 'k@example.com');
      expect(creds.profile.name, 'Karthikeyan S');
    });

    test('user denying consent maps to SignInCancelledException', () async {
      final backend = DesktopLoopbackAuthBackend(
        config: config,
        api: GoogleOAuthApi(_FakeGoogle().dio),
        openUrl: (url) async {
          unawaited(
            HttpClient()
                .getUrl(
                  Uri.parse(url.queryParameters['redirect_uri']!).replace(
                    queryParameters: {
                      'error': 'access_denied',
                      'state': url.queryParameters['state']!,
                    },
                  ),
                )
                .then((r) => r.close())
                .then((r) => r.drain<void>()),
          );
          return true;
        },
      );
      await expectLater(
        backend.signIn(),
        throwsA(isA<SignInCancelledException>()),
      );
    });

    test('stray local requests with wrong state are ignored', () async {
      final google = _FakeGoogle();
      final backend = DesktopLoopbackAuthBackend(
        config: config,
        api: GoogleOAuthApi(google.dio),
        clock: () => now,
        openUrl: (url) async {
          final q = url.queryParameters;
          final redirect = Uri.parse(q['redirect_uri']!);
          Future<int> hit(Map<String, String> params) async {
            final res = await (await HttpClient().getUrl(
              redirect.replace(queryParameters: params),
            )).close();
            await res.drain<void>();
            return res.statusCode;
          }

          unawaited(() async {
            // Attacker / stale redirects without the right state.
            expect(await hit({'error': 'access_denied'}), 400);
            expect(await hit({'code': 'evil', 'state': 'bogus'}), 400);
            // The real redirect still completes sign-in.
            await hit({'code': 'auth-code', 'state': q['state']!});
          }());
          return true;
        },
      );
      final creds = await backend.signIn();
      expect(creds.accessToken, 'access-1');
      expect(google.requests.single['code'], 'auth-code');
    });

    test('invalid_client (HTTP 401) is a config error, not expiry', () async {
      final google = _FakeGoogle()..badClient = true;
      final backend = DesktopLoopbackAuthBackend(
        config: config,
        api: GoogleOAuthApi(google.dio),
      );
      final current = StoredCredentials(
        accessToken: 'old',
        expiresAt: now,
        refreshToken: 'refresh-1',
        profile: _user,
      );
      await expectLater(
        backend.refresh(current),
        throwsA(isA<AuthConfigException>()),
      );
    });

    test('missing client config fails fast', () async {
      final backend = DesktopLoopbackAuthBackend(
        config: const AuthConfig(
          androidServerClientId: '',
          desktopClientId: '',
          desktopClientSecret: '',
        ),
        openUrl: (_) async => fail('should not open browser'),
      );
      await expectLater(backend.signIn(), throwsA(isA<AuthConfigException>()));
    });

    test('refresh keeps refresh token; invalid_grant → AuthExpired', () async {
      final google = _FakeGoogle();
      final backend = DesktopLoopbackAuthBackend(
        config: config,
        api: GoogleOAuthApi(google.dio),
        clock: () => now,
      );
      final current = StoredCredentials(
        accessToken: 'old',
        expiresAt: now,
        refreshToken: 'refresh-1',
        profile: _user,
      );

      final refreshed = await backend.refresh(current);
      expect(refreshed.accessToken, 'access-1');
      expect(refreshed.refreshToken, 'refresh-1');
      expect(google.requests.last['grant_type'], 'refresh_token');

      expect(
        await GoogleOAuthApi(google.dio).tokenLifetime('old'),
        const Duration(seconds: 100),
      );

      google.revoked = true;
      await expectLater(
        backend.refresh(current),
        throwsA(isA<AuthExpiredException>()),
      );
      expect(await backend.isAccessTokenValid('old'), isFalse);
      expect(await GoogleOAuthApi(google.dio).tokenLifetime('old'), isNull);
    });
  });
}

/// Fakes Google's token/userinfo/tokeninfo endpoints at the Dio adapter level.
class _FakeGoogle implements HttpClientAdapter {
  _FakeGoogle() {
    dio.httpClientAdapter = this;
  }

  final Dio dio = Dio();
  final List<Map<String, String>> requests = [];
  bool revoked = false;
  bool badClient = false;
  int _issued = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    // Check /tokeninfo before /token (prefix).
    if (url.startsWith(GoogleOAuthApi.tokenInfoEndpoint)) {
      return revoked
          ? _json(400, {'error': 'invalid_token'})
          // Google returns expires_in as a string here.
          : _json(200, {'expires_in': '100'});
    }
    if (url.startsWith(GoogleOAuthApi.tokenEndpoint)) {
      final body = options.data as Map<String, dynamic>;
      requests.add(body.map((k, v) => MapEntry(k, '$v')));
      if (badClient) return _json(401, {'error': 'invalid_client'});
      if (revoked) return _json(400, {'error': 'invalid_grant'});
      _issued++;
      return _json(200, {
        'access_token': 'access-$_issued',
        'expires_in': 3599,
        if (body['grant_type'] == 'authorization_code')
          'refresh_token': 'refresh-$_issued',
      });
    }
    if (url.startsWith(GoogleOAuthApi.userInfoEndpoint)) {
      return _json(200, {
        'sub': '42',
        'email': 'k@example.com',
        'name': 'Karthikeyan S',
        'picture': 'https://example.com/p.png',
      });
    }
    return _json(404, {});
  }

  ResponseBody _json(int status, Object body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}
