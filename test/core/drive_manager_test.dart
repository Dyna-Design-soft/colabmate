import 'dart:async';
import 'dart:convert';

import 'package:colabmate/core/auth/auth_backend.dart';
import 'package:colabmate/core/auth/auth_exceptions.dart';
import 'package:colabmate/core/auth/auth_manager.dart';
import 'package:colabmate/core/auth/token_storage.dart';
import 'package:colabmate/core/drive/drive_manager.dart';
import 'package:colabmate/core/drive/notebook_cache.dart';
import 'package:colabmate/db/database.dart';
import 'package:colabmate/models/notebook.dart';
import 'package:colabmate/models/user_profile.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

// --- Auth fakes --------------------------------------------------------------

class _MemoryStore implements SecureKeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

class _Backend implements AuthBackend {
  int refreshes = 0;
  Object? refreshError;

  StoredCredentials _creds(String token) => StoredCredentials(
    accessToken: token,
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    profile: const UserProfile(id: '1', email: 'k@example.com'),
  );

  @override
  Future<StoredCredentials> signIn() async => _creds('token-0');
  @override
  Future<StoredCredentials> refresh(StoredCredentials c) async {
    refreshes++;
    if (refreshError != null) throw refreshError!;
    return _creds('token-$refreshes');
  }

  @override
  Future<bool> isAccessTokenValid(String t) async => true;
  @override
  Future<void> signOut(StoredCredentials? c) async {}
}

// --- Fake Google Drive -------------------------------------------------------

String _nb(String code) => jsonEncode({
  'nbformat': 4,
  'nbformat_minor': 0,
  'metadata': {},
  'cells': [
    {'cell_type': 'code', 'metadata': {}, 'source': code, 'outputs': []},
  ],
});

class _FakeDrive implements HttpClientAdapter {
  bool offline = false;

  /// Tokens that Drive accepts; others get 401.
  Set<String> validTokens = {'Bearer token-0'};

  final Map<String, Map<String, dynamic>> files = {
    'nb1': {
      'id': 'nb1',
      'name': 'Training.ipynb',
      'mimeType': 'application/vnd.google.colaboratory',
      'modifiedTime': '2026-10-30T10:00:00.000Z',
      'content': _nb('print("train")'),
    },
    'nb2': {
      'id': 'nb2',
      'name': 'analysis.ipynb',
      'mimeType': 'application/json',
      'modifiedTime': '2026-10-31T10:00:00.000Z',
      'content': _nb('x = 1'),
    },
    'txt': {
      'id': 'txt',
      'name': 'notes about ipynb.txt',
      'mimeType': 'text/plain',
      'modifiedTime': '2026-10-31T11:00:00.000Z',
      'content': 'hello',
    },
  };

  final List<RequestOptions> uploads = [];
  Completer<void>? uploadGate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? body,
    Future<void>? cancel,
  ) async {
    if (offline) {
      throw DioException.connectionError(requestOptions: o, reason: 'offline');
    }
    if (!validTokens.contains(o.headers['Authorization'])) {
      return _json(401, {
        'error': {'message': 'Invalid Credentials'},
      });
    }
    final path = o.uri.path;
    if (o.method == 'GET' && path == '/drive/v3/files') {
      return _json(200, {
        'files': [
          for (final f in files.values)
            {
              for (final k in ['id', 'name', 'mimeType', 'modifiedTime'])
                k: f[k],
            },
        ],
      });
    }
    if (o.method == 'GET' && path.startsWith('/drive/v3/files/')) {
      final f = files[path.split('/').last];
      if (f == null) {
        return _json(404, {
          'error': {'message': 'File not found'},
        });
      }
      if (o.uri.queryParameters['alt'] == 'media') {
        return ResponseBody.fromString(f['content'] as String, 200);
      }
      return _json(200, {
        for (final k in ['id', 'name', 'mimeType', 'modifiedTime']) k: f[k],
      });
    }
    if (o.method == 'PATCH' && path.startsWith('/upload/drive/v3/files/')) {
      uploads.add(o);
      await uploadGate?.future;
      final f = files[path.split('/').last];
      if (f == null) {
        return _json(404, {
          'error': {'message': 'File not found'},
        });
      }
      f['content'] = o.data as String;
      return _json(200, {'id': f['id']});
    }
    return _json(400, {
      'error': {'message': 'unexpected ${o.method} $path'},
    });
  }

  ResponseBody _json(int status, Object data) => ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late NotebookCache cache;
  late _FakeDrive drive;
  late _Backend backend;
  late AuthManager auth;

  DriveManager manager() => DriveManager(
    auth: auth,
    cache: cache,
    dio: Dio()..httpClientAdapter = drive,
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    cache = NotebookCache(db);
    drive = _FakeDrive();
    backend = _Backend();
    auth = AuthManager(backend: backend, storage: TokenStorage(_MemoryStore()));
    await auth.signIn();
  });

  tearDown(() => db.close());

  test('D1: lists only notebooks, newest first, and caches the list', () async {
    final listing = await manager().listNotebooks();
    expect(listing.fromCache, isFalse);
    expect(listing.notebooks.map((n) => n.name), [
      'analysis.ipynb',
      'Training.ipynb',
    ]);
    expect(await cache.listMeta(), hasLength(2));
  });

  test('offline listing falls back to the cache', () async {
    final dm = manager();
    await dm.listNotebooks();
    drive.offline = true;
    final listing = await dm.listNotebooks();
    expect(listing.fromCache, isTrue);
    expect(listing.notebooks, hasLength(2));
  });

  test('D2: reads and parses a notebook, caching it', () async {
    final nb = await manager().readNotebook('nb1');
    expect(nb.name, 'Training.ipynb');
    expect(nb.cells.single.source, 'print("train")');
    expect(nb.pendingSync, isFalse);
    expect((await cache.get('nb1'))!.cells.single.source, 'print("train")');
  });

  test('D3: opened notebook loads from cache when offline', () async {
    final dm = manager();
    await dm.readNotebook('nb1');
    drive.offline = true;
    final nb = await dm.readNotebook('nb1');
    expect(nb.cells.single.source, 'print("train")');
  });

  test('offline read of a never-opened notebook throws offline', () async {
    drive.offline = true;
    await expectLater(
      manager().readNotebook('nb2'),
      throwsA(isA<DriveOfflineException>()),
    );
  });

  test('D4–D6: offline edit is queued, then synced to Drive', () async {
    final dm = manager();
    final nb = await dm.readNotebook('nb1');

    drive.offline = true;
    final saved = await dm.saveNotebook(nb.updateCell(0, 'print("edited")'));
    expect(saved.pendingSync, isTrue);
    expect((await cache.pending()).single.id, 'nb1');
    // Listing shows the pending indicator.
    expect(
      (await dm.listNotebooks()).notebooks
          .firstWhere((n) => n.id == 'nb1')
          .pendingSync,
      isTrue,
    );
    // Re-opening offline shows the local edit.
    expect(
      (await dm.readNotebook('nb1')).cells.single.source,
      'print("edited")',
    );

    drive.offline = false;
    // Reopening already kicked off a background sync, which may finish
    // first; either way, every attempt must succeed and nothing stays queued.
    final results = await dm.syncPending();
    expect(results.every((r) => r.ok), isTrue);
    expect(await cache.pending(), isEmpty);

    // Drive got the edit, with the Colab MIME type kept.
    final upload = drive.uploads.single;
    expect(upload.contentType, 'application/vnd.google.colaboratory');
    final onDrive = Notebook.fromIpynb(
      id: 'nb1',
      name: 'x',
      json: drive.files['nb1']!['content'] as String,
    );
    expect(onDrive.cells.single.source, 'print("edited")');
  });

  test('online save uploads immediately', () async {
    final dm = manager();
    final nb = await dm.readNotebook('nb2');
    final saved = await dm.saveNotebook(nb.updateCell(0, 'x = 2'));
    expect(saved.pendingSync, isFalse);
    expect(await cache.pending(), isEmpty);
    expect(drive.uploads, hasLength(1));
  });

  test('local unsynced edit wins over Drive when reopening', () async {
    final dm = manager();
    final nb = await dm.readNotebook('nb1');
    drive.offline = true;
    await dm.saveNotebook(nb.updateCell(0, 'local'));
    drive.offline = false;
    drive.files['nb1']!['content'] = _nb('changed in Colab web');
    final reopened = await dm.readNotebook('nb1');
    expect(reopened.cells.single.source, 'local');
  });

  test('edit made during an upload stays pending', () async {
    final dm = manager();
    final nb = await dm.readNotebook('nb1');
    drive.offline = true;
    await dm.saveNotebook(nb.updateCell(0, 'v1'));
    drive.offline = false;

    drive.uploadGate = Completer<void>();
    final sync = dm.syncPending();
    await Future<void>.delayed(Duration.zero);
    // A newer edit lands in the cache while v1 is uploading.
    await cache.putPending(nb.updateCell(0, 'v2'));
    drive.uploadGate!.complete();
    await sync;

    expect((await cache.pending()).single.cells.single.source, 'v2');
  });

  test('listing keeps unsynced notebooks even if gone from Drive', () async {
    final dm = manager();
    final nb = await dm.readNotebook('nb1');
    drive.offline = true;
    await dm.saveNotebook(nb.updateCell(0, 'keep me'));
    drive.offline = false;
    drive.files.remove('nb1');
    // Sync will fail (404) but the edit must not be lost.
    final listing = await dm.listNotebooks();
    expect(listing.notebooks.map((n) => n.id), contains('nb1'));
    expect(await cache.get('nb1'), isNotNull);
  });

  test('sync reports per-file failures', () async {
    final dm = manager();
    final nb = await dm.readNotebook('nb1');
    drive.offline = true;
    await dm.saveNotebook(nb.updateCell(0, 'x'));
    drive.offline = false;
    drive.files.remove('nb1');
    final results = await dm.syncPending();
    expect(results.single.ok, isFalse);
    expect(results.single.error, isA<NotebookNotFoundException>());
    expect(await cache.pending(), hasLength(1), reason: 'kept for retry');
  });

  test('401 → token refreshed once and request retried', () async {
    final dm = manager();
    drive.validTokens = {'Bearer token-1'};
    final listing = await dm.listNotebooks();
    expect(listing.notebooks, hasLength(2));
    expect(backend.refreshes, 1);
  });

  test('revoked access surfaces as AuthExpired, not "offline"', () async {
    final dm = manager();
    drive.validTokens = {};
    backend.refreshError = const AuthExpiredException();
    await expectLater(dm.listNotebooks(), throwsA(isA<AuthExpiredException>()));
  });

  test('missing file → NotebookNotFoundException', () async {
    await expectLater(
      manager().readNotebook('nope'),
      throwsA(isA<NotebookNotFoundException>()),
    );
  });
}
