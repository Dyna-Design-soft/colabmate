import 'dart:async';
import 'dart:convert';

import 'package:colabmate/core/auth/auth_backend.dart';
import 'package:colabmate/core/auth/auth_manager.dart';
import 'package:colabmate/core/auth/token_storage.dart';
import 'package:colabmate/core/runtime/colab_api.dart';
import 'package:colabmate/core/runtime/jupyter_client.dart';
import 'package:colabmate/core/runtime/runtime_manager.dart';
import 'package:colabmate/core/runtime/websocket_handler.dart';
import 'package:colabmate/models/output_chunk.dart';
import 'package:colabmate/models/runtime_status.dart';
import 'package:colabmate/models/user_profile.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// --- Fakes -------------------------------------------------------------------

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
  @override
  Future<StoredCredentials> signIn() async => StoredCredentials(
    accessToken: 't',
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
  }) async =>
      ScopedToken('colab', DateTime.now().add(const Duration(hours: 1)));
}

/// Fake kernel WebSocket: records sent messages, lets tests push replies.
class _FakeSocket implements KernelSocket {
  _FakeSocket(this.uri, this.headers, {this.failHandshake = false});

  final Uri uri;
  final Map<String, String> headers;
  final bool failHandshake;
  final sent = <Map<String, dynamic>>[];
  final _incoming = StreamController<String>();

  @override
  Future<void> get ready => failHandshake
      ? Future.error(Exception('handshake failed'))
      : Future.value();

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String message) =>
      sent.add((jsonDecode(message) as Map).cast<String, dynamic>());

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  /// Simulates the server dropping the connection.
  Future<void> drop() => _incoming.close();

  void reply(
    String type,
    Map<String, dynamic> content, {
    required String parent,
    String channel = 'iopub',
  }) {
    _incoming.add(
      jsonEncode({
        'header': {'msg_type': type, 'msg_id': 'srv-${sent.length}'},
        'parent_header': {'msg_id': parent},
        'content': content,
        'channel': channel,
      }),
    );
  }

  String get lastMsgId => (sent.last['header'] as Map)['msg_id'] as String;
}

/// Fake Colab API + Jupyter server at the HTTP level.
class _FakeHttp implements HttpClientAdapter {
  List<Map<String, dynamic>> kernels = [];
  int kernelsStarted = 0;
  int getRuntimeCalls = 0;
  int opPolls = 0;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<List<int>>? body,
    Future<void>? cancel,
  ) async {
    requests.add(o);
    final path = o.uri.path;
    if (o.uri.host == 'colaboratory.googleapis.com') {
      if (path == '/v1beta/runtimes/r1' && o.method == 'GET') {
        getRuntimeCalls++;
        return _json(200, _runtime(expire: '2099-01-01T00:00:00Z'));
      }
      if (path == '/v1beta/runtimes' && o.method == 'POST') {
        return _json(200, {'name': 'operations/op1', 'done': false});
      }
      if (path == '/v1/operations/op1:wait') {
        opPolls++;
        return _json(
          200,
          opPolls < 2
              ? {'name': 'operations/op1', 'done': false}
              : {
                  'name': 'operations/op1',
                  'done': true,
                  'response': _runtime(expire: '2099-01-01T00:00:00Z'),
                },
        );
      }
    }
    if (o.uri.host == 'rt.colab.dev') {
      if (o.headers[kColabProxyTokenHeader] != 'fresh-token') {
        return _json(403, {'error': 'bad proxy token'});
      }
      if (path == '/api/kernels' && o.method == 'GET') {
        return _json(200, kernels);
      }
      if (path == '/api/kernels' && o.method == 'POST') {
        kernelsStarted++;
        return _json(201, {'id': 'k-new', 'name': 'python3'});
      }
      if (path == '/api/colab/resources') {
        return _json(200, {
          'memory': {'totalBytes': 13000000000, 'freeBytes': 10000000000},
          'disks': [
            {
              'filesystem': {
                'totalBytes': '100000000000',
                'usedBytes': 30000000000,
              },
            },
          ],
          'gpus': [
            {
              'name': 'Tesla T4',
              'gpuUtilization': 0.42,
              'memoryUsedBytes': 1500000000,
              'memoryTotalBytes': 15000000000,
            },
          ],
        });
      }
    }
    return _json(404, {'error': 'unexpected ${o.method} ${o.uri}'});
  }

  Map<String, dynamic> _runtime({required String expire}) => {
    'name': 'runtimes/r1',
    'runtimeSpec': {
      'variant': 'VARIANT_GPU',
      'accelerator': 'T4',
      'shape': 'SHAPE_STANDARD',
    },
    'connectionInfo': {
      'url': 'https://rt.colab.dev',
      'token': 'fresh-token',
      'expireTime': expire,
    },
  };

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

const _staleRuntime = RuntimeInfo(
  name: 'runtimes/r1',
  spec: RuntimeSpecKey(
    variant: RuntimeVariant.gpu,
    shape: RuntimeShape.standard,
    accelerator: 'T4',
  ),
  connection: RuntimeConnection(
    url: 'https://rt.colab.dev',
    token: 'old-token',
    expireTime: null,
  ),
);

void main() {
  group('KernelConnection (Jupyter messaging)', () {
    late _FakeSocket socket;
    late KernelConnection conn;

    setUp(() async {
      conn = await KernelConnection.open(
        Uri.parse('wss://x/api/kernels/k1/channels'),
        const {},
        sessionId: 's1',
        socketFactory: (u, h) => socket = _FakeSocket(u, h),
      );
    });

    test('sends execute_request and streams output until done', () async {
      final chunks = <OutputChunk>[];
      final done = conn.execute("print('hello ColabMate')").listen(chunks.add);

      final req = socket.sent.single;
      expect((req['header'] as Map)['msg_type'], 'execute_request');
      expect(req['channel'], 'shell');
      expect((req['content'] as Map)['code'], "print('hello ColabMate')");
      final id = socket.lastMsgId;

      socket
        ..reply('status', {'execution_state': 'busy'}, parent: id)
        ..reply('stream', {'name': 'stdout', 'text': 'hello '}, parent: id)
        ..reply('stream', {'name': 'stdout', 'text': 'ColabMate\n'}, parent: id)
        // Output for some other request must be ignored.
        ..reply('stream', {'name': 'stdout', 'text': 'noise'}, parent: 'other')
        ..reply(
          'execute_reply',
          {'status': 'ok', 'execution_count': 7},
          parent: id,
          channel: 'shell',
        )
        ..reply('status', {'execution_state': 'idle'}, parent: id);
      await done.asFuture<void>();

      expect(
        chunks.whereType<StreamChunk>().map((c) => c.text).join(),
        'hello ColabMate\n',
      );
      final last = chunks.last as DoneChunk;
      expect(last.ok, isTrue);
      expect(last.executionCount, 7);
    });

    test('streams progressively (R4), not all at the end', () async {
      final received = <String>[];
      conn.execute('for i in range(3): print(i); time.sleep(1)').listen((c) {
        if (c is StreamChunk) received.add(c.text);
      });
      final id = socket.lastMsgId;
      socket.reply('stream', {'name': 'stdout', 'text': '0\n'}, parent: id);
      await Future<void>.delayed(Duration.zero);
      expect(received, ['0\n'], reason: 'first line arrives before the end');
    });

    test('errors (R3): traceback, then Done(ok: false)', () async {
      final chunks = <OutputChunk>[];
      final sub = conn.execute('1/0').listen(chunks.add);
      final id = socket.lastMsgId;
      socket
        ..reply('error', {
          'ename': 'ZeroDivisionError',
          'evalue': 'division by zero',
          'traceback': ['\x1B[0;31mZeroDivisionError\x1B[0m: division by zero'],
        }, parent: id)
        ..reply('status', {'execution_state': 'idle'}, parent: id)
        ..reply('execute_reply', {'status': 'error'}, parent: id);
      await sub.asFuture<void>();
      final err = chunks.whereType<ErrorChunk>().single;
      expect(err.ename, 'ZeroDivisionError');
      expect(err.plainTraceback, 'ZeroDivisionError: division by zero');
      expect((chunks.last as DoneChunk).ok, isFalse);
    });

    test('rich results: text and PNG', () async {
      final chunks = <OutputChunk>[];
      final sub = conn.execute('x').listen(chunks.add);
      final id = socket.lastMsgId;
      socket
        ..reply('execute_result', {
          'data': {'text/plain': '42'},
          'execution_count': 1,
        }, parent: id)
        ..reply('display_data', {
          'data': {'image/png': 'iVBORw0KGgo=\n'},
        }, parent: id)
        ..reply('execute_reply', {'status': 'ok'}, parent: id)
        ..reply('status', {'execution_state': 'idle'}, parent: id);
      await sub.asFuture<void>();
      final rich = chunks.whereType<RichChunk>().toList();
      expect(rich[0].plainText, '42');
      expect(rich[1].pngBase64, 'iVBORw0KGgo=');
    });

    test('connection drop mid-run ends the run with an error', () async {
      final chunks = <OutputChunk>[];
      final sub = conn.execute('time.sleep(100)').listen(chunks.add);
      await socket.drop();
      await sub.asFuture<void>();
      expect(
        chunks.whereType<ErrorChunk>().single.evalue,
        'Runtime disconnected',
      );
      expect((chunks.last as DoneChunk).ok, isFalse);
      expect(conn.status, KernelStatus.disconnected);
    });

    test('kernel status is tracked', () async {
      final states = <KernelStatus>[];
      conn.statusChanges.listen(states.add);
      socket.reply('status', {'execution_state': 'busy'}, parent: 'x');
      socket.reply('status', {'execution_state': 'idle'}, parent: 'x');
      await Future<void>.delayed(Duration.zero);
      expect(states, [KernelStatus.busy, KernelStatus.idle]);
    });
  });

  group('RuntimeManager', () {
    late _FakeHttp http;
    late RuntimeManager manager;
    late List<_FakeSocket> sockets;
    var failNextHandshakes = 0;

    setUp(() async {
      http = _FakeHttp();
      sockets = [];
      failNextHandshakes = 0;
      final auth = AuthManager(
        backend: _Backend(),
        storage: TokenStorage(_Mem()),
      );
      await auth.signIn();
      final dio = Dio()..httpClientAdapter = http;
      manager = RuntimeManager(
        colab: ColabApi(auth: auth, dio: dio),
        jupyterFactory: (base, token) => JupyterClient(
          baseUrl: base,
          token: token,
          dio: Dio()..httpClientAdapter = http,
        ),
        socketFactory: (uri, headers) {
          final s = _FakeSocket(
            uri,
            headers,
            failHandshake: failNextHandshakes-- > 0,
          );
          sockets.add(s);
          return s;
        },
        reconnectDelay: Duration.zero,
      );
    });

    test('connect: refreshes connection info, reuses latest kernel', () async {
      http.kernels = [
        {
          'id': 'k-old',
          'name': 'python3',
          'last_activity': '2026-11-01T08:00:00Z',
        },
        {
          'id': 'k-recent',
          'name': 'python3',
          'last_activity': '2026-11-01T10:00:00Z',
        },
      ];
      final session = await manager.connectRuntime(_staleRuntime);
      expect(http.getRuntimeCalls, 1, reason: 'token had no expiry → refresh');
      expect(session.kernelId, 'k-recent');
      expect(http.kernelsStarted, 0);

      final ws = sockets.single;
      expect(ws.uri.scheme, 'wss');
      expect(ws.uri.path, '/api/kernels/k-recent/channels');
      expect(ws.uri.queryParameters['session_id'], session.sessionId);
      expect(ws.headers[kColabProxyTokenHeader], 'fresh-token');
      expect(session.status, KernelStatus.idle);
    });

    test('connect: starts a kernel when none is running', () async {
      final session = await manager.connectRuntime(_staleRuntime);
      expect(session.kernelId, 'k-new');
      expect(http.kernelsStarted, 1);
    });

    test('hello ColabMate end to end', () async {
      final session = await manager.connectRuntime(_staleRuntime);
      final out = <OutputChunk>[];
      final sub = manager
          .executeCell(session, "print('hello ColabMate')")
          .listen(out.add);
      final ws = sockets.single;
      final id = ws.lastMsgId;
      ws
        ..reply('stream', {
          'name': 'stdout',
          'text': 'hello ColabMate\n',
        }, parent: id)
        ..reply('execute_reply', {
          'status': 'ok',
          'execution_count': 1,
        }, parent: id)
        ..reply('status', {'execution_state': 'idle'}, parent: id);
      await sub.asFuture<void>();
      expect((out.first as StreamChunk).text, 'hello ColabMate\n');
      expect((out.last as DoneChunk).ok, isTrue);
    });

    test('auto-reconnect after a dropped connection', () async {
      final session = await manager.connectRuntime(_staleRuntime);
      await sockets.single.drop();
      await pumpEventQueue();
      expect(sockets, hasLength(2), reason: 'reconnected once');
      expect(session.status, KernelStatus.idle);
    });

    test('gives up after 3 failed reconnects → disconnected (R5)', () async {
      final session = await manager.connectRuntime(_staleRuntime);
      final states = <KernelStatus>[];
      session.statusChanges.listen(states.add);
      failNextHandshakes = 3;
      await sockets.single.drop();
      await pumpEventQueue(times: 50);
      expect(sockets, hasLength(4), reason: '1 original + 3 attempts');
      expect(session.status, KernelStatus.disconnected);
      expect(states.last, KernelStatus.disconnected);
      // Running a cell now fails cleanly.
      final out = await manager.executeCell(session, 'x').toList();
      expect((out.last as DoneChunk).ok, isFalse);
    });

    test('startRuntime polls the operation until Colab assigns it', () async {
      final runtime = await manager.startRuntime(
        const RuntimeSpecKey(
          variant: RuntimeVariant.gpu,
          shape: RuntimeShape.standard,
          accelerator: 'T4',
        ),
      );
      expect(http.opPolls, 2);
      expect(runtime.name, 'runtimes/r1');
      final post = http.requests.firstWhere((r) => r.method == 'POST');
      expect((post.data as Map)['runtimeSpec'], {
        'variant': 'VARIANT_GPU',
        'shape': 'SHAPE_STANDARD',
        'accelerator': 'T4',
      });
    });

    test('resources: RAM, disk and GPU parsed (R6 / FR-03)', () async {
      final res = await manager.getResourcesFor(_staleRuntime);
      expect(res.ramTotalBytes, 13000000000);
      expect(res.ramUsedBytes, 3000000000);
      expect(res.diskTotalBytes, 100000000000);
      expect(res.diskUsedBytes, 30000000000);
      expect(res.gpus.single.name, 'Tesla T4');
      expect(res.gpus.single.utilization, closeTo(0.42, 1e-9));
      expect(res.gpus.single.memoryFraction, closeTo(0.1, 1e-9));
    });

    test('disconnect closes the socket and stops reconnecting', () async {
      final session = await manager.connectRuntime(_staleRuntime);
      await manager.disconnectRuntime(session);
      await pumpEventQueue();
      expect(sockets, hasLength(1));
      expect(session.status, KernelStatus.disconnected);
    });
  });
}
