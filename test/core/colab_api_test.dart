import 'dart:convert';

import 'package:colabmate/core/auth/auth_backend.dart';
import 'package:colabmate/core/auth/auth_exceptions.dart';
import 'package:colabmate/core/auth/auth_manager.dart';
import 'package:colabmate/core/auth/token_storage.dart';
import 'package:colabmate/core/runtime/colab_api.dart';
import 'package:colabmate/models/runtime_status.dart';
import 'package:colabmate/models/user_profile.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Mem implements SecureKeyValueStore {
  final m = <String, String>{};
  @override
  Future<String?> read(String k) async => m[k];
  @override
  Future<void> write(String k, String v) async => m[k] = v;
  @override
  Future<void> delete(String k) async => m.remove(k);
}

class _Backend implements AuthBackend {
  bool colabGranted = true;
  int scoped = 0;
  final List<List<String>> requestedScopes = [];

  @override
  Future<StoredCredentials> signIn() async => StoredCredentials(
    accessToken: 'drive-token',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    profile: const UserProfile(id: '1', email: 'k@example.com'),
  );
  @override
  Future<StoredCredentials> refresh(StoredCredentials c) => signIn();
  @override
  Future<bool> isAccessTokenValid(String t) async => true;
  @override
  Future<void> signOut(StoredCredentials? c) async {}
  @override
  Future<ScopedToken?> scopedToken(
    List<String> scopes, {
    required bool interactive,
    String? stale,
  }) async {
    requestedScopes.add(scopes);
    if (!colabGranted) return null;
    scoped++;
    return ScopedToken(
      'colab-$scoped',
      DateTime.now().add(const Duration(hours: 1)),
    );
  }
}

class _FakeColab implements HttpClientAdapter {
  Object? Function(RequestOptions o)? respond;
  final List<RequestOptions> requests = [];
  Set<String> validTokens = {'Bearer colab-1'};

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? body,
    Future<void>? cancel,
  ) async {
    requests.add(o);
    final custom = respond?.call(o);
    if (custom is ResponseBody) return custom;
    if (custom is Exception) throw custom;
    if (!validTokens.contains(o.headers['Authorization'])) {
      return _json(401, {
        'error': {'code': 401, 'message': 'Request had invalid credentials.'},
      });
    }
    return switch (o.uri.path) {
      '/v1beta/subscription' => _json(200, {
        'name': 'subscription',
        'tier': 'SUBSCRIPTION_TIER_FREE',
      }),
      '/v1beta/runtimespecs' => _json(200, {
        'runtimeSpecs': [
          {
            'key': {'variant': 'VARIANT_CPU', 'shape': 'SHAPE_STANDARD'},
            'eligible': true,
          },
          {
            'key': {
              'variant': 'VARIANT_GPU',
              'accelerator': 'T4',
              'shape': 'SHAPE_STANDARD',
            },
            'eligible': true,
          },
          {
            'key': {
              'variant': 'VARIANT_GPU',
              'accelerator': 'A100',
              'shape': 'SHAPE_HIGHMEM',
            },
            'eligible': false,
          },
        ],
      }),
      '/v1beta/runtimes' => _json(200, {
        'runtimes': [
          {
            'name': 'runtimes/abc123',
            'runtimeSpec': {
              'variant': 'VARIANT_GPU',
              'accelerator': 'T4',
              'shape': 'SHAPE_STANDARD',
            },
            'version': '2026.10',
            'connectionInfo': {
              'url': 'https://8080-m-s-abc.prod.colab.dev',
              'token': 'proxy-token',
              'expireTime': '2026-11-01T12:00:00Z',
            },
          },
        ],
      }),
      _ => _json(404, {
        'error': {'message': 'not found'},
      }),
    };
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, Object body) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  late _Backend backend;
  late _FakeColab colab;
  late ColabApi api;

  setUp(() async {
    backend = _Backend();
    colab = _FakeColab();
    final auth = AuthManager(backend: backend, storage: TokenStorage(_Mem()));
    await auth.signIn();
    api = ColabApi(auth: auth, dio: Dio()..httpClientAdapter = colab);
  });

  test('uses the Colab scope token, not the Drive token', () async {
    await api.getSubscription();
    expect(colab.requests.single.headers['Authorization'], 'Bearer colab-1');
    expect(backend.requestedScopes.first, kColabScopes);
    expect(colab.requests.single.uri.host, 'colaboratory.googleapis.com');
  });

  test('parses plan, runtime types and runtimes', () async {
    expect(await api.getSubscription(), SubscriptionTier.free);

    final specs = await api.listRuntimeSpecs();
    expect(specs.map((s) => s.key.label), ['CPU', 'T4 GPU', 'A100 GPU']);
    expect(specs.map((s) => s.eligible), [true, true, false]);
    expect(specs[2].key.shape, RuntimeShape.highMem);

    final runtime = (await api.listRuntimes()).single;
    expect(runtime.id, 'abc123');
    expect(runtime.spec.label, 'T4 GPU');
    expect(runtime.connection!.url, 'https://8080-m-s-abc.prod.colab.dev');
    expect(runtime.connection!.token, 'proxy-token');
  });

  test(
    'not granted → ScopeNotGrantedException (UI shows Allow button)',
    () async {
      backend.colabGranted = false;
      expect(await api.hasAccess(), isFalse);
      await expectLater(
        api.getSubscription(),
        throwsA(isA<ScopeNotGrantedException>()),
      );
    },
  );

  test('401 → Colab token refreshed and retried', () async {
    colab.validTokens = {'Bearer colab-2'};
    expect(await api.getSubscription(), SubscriptionTier.free);
    expect(backend.scoped, 2);
  });

  test('API disabled in Cloud project → clear message', () async {
    colab.respond = (_) => _json(403, {
      'error': {
        'code': 403,
        'message': 'Colab API has not been used in project 599880011741',
        'status': 'PERMISSION_DENIED',
        'details': [
          {
            '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
            'reason': 'SERVICE_DISABLED',
          },
        ],
      },
    });
    await expectLater(
      api.getSubscription(),
      throwsA(
        isA<ColabApiException>()
            .having((e) => e.reason, 'reason', 'SERVICE_DISABLED')
            .having((e) => e.message, 'message', contains('not enabled')),
      ),
    );
  });

  test('other errors keep Google\'s message for diagnosis', () async {
    colab.respond = (_) => _json(403, {
      'error': {'code': 403, 'message': 'Caller is not allowlisted.'},
    });
    await expectLater(
      api.listRuntimeSpecs(),
      throwsA(
        isA<ColabApiException>().having(
          (e) => e.message,
          'message',
          contains('Caller is not allowlisted.'),
        ),
      ),
    );
  });

  test('no network → ColabOfflineException', () async {
    colab.respond = (o) =>
        DioException.connectionError(requestOptions: o, reason: 'offline');
    await expectLater(
      api.listRuntimes(),
      throwsA(isA<ColabOfflineException>()),
    );
  });
}
