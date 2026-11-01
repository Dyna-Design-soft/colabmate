import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';

import '../../models/output_chunk.dart';
import '../../models/runtime_status.dart';

/// Minimal WebSocket abstraction (so tests can use a fake).
abstract interface class KernelSocket {
  /// Completes once connected; throws if the handshake fails.
  Future<void> get ready;
  Stream<String> get messages;
  void send(String message);
  Future<void> close();
}

typedef KernelSocketFactory = KernelSocket Function(
  Uri uri,
  Map<String, String> headers,
);

KernelSocket ioKernelSocket(Uri uri, Map<String, String> headers) =>
    _IoKernelSocket(uri, headers);

class _IoKernelSocket implements KernelSocket {
  _IoKernelSocket(Uri uri, Map<String, String> headers)
    : _channel = IOWebSocketChannel.connect(
        uri,
        headers: headers,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 20),
      );

  final IOWebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<String> get messages =>
      _channel.stream.map((m) => m is String ? m : utf8.decode(m as List<int>));

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() async => _channel.sink.close();
}

/// A live connection to one kernel's message channels (Jupyter messaging
/// protocol 5.x over WebSocket, JSON framing). Streams cell output in real
/// time (spec §4.3 "Output Streaming", FR-04, NFR-03).
class KernelConnection {
  KernelConnection._(this._socket, this.sessionId) {
    _sub = _socket.messages.listen(
      _onMessage,
      onError: (Object e) => _onClosed(e),
      onDone: () => _onClosed(null),
    );
  }

  /// Opens the WebSocket. Throws if the handshake fails.
  static Future<KernelConnection> open(
    Uri uri,
    Map<String, String> headers, {
    required String sessionId,
    KernelSocketFactory socketFactory = ioKernelSocket,
  }) async {
    final socket = socketFactory(uri, headers);
    await socket.ready;
    return KernelConnection._(socket, sessionId);
  }

  final KernelSocket _socket;
  final String sessionId;
  late final StreamSubscription<String> _sub;

  final Map<String, _Execution> _executions = {};
  final _status = StreamController<KernelStatus>.broadcast();
  final _closed = Completer<Object?>();
  KernelStatus _lastStatus = KernelStatus.idle;

  static final Random _random = Random();

  KernelStatus get status => _lastStatus;
  Stream<KernelStatus> get statusChanges => _status.stream;

  /// Completes (with the error, if any) when the socket closes.
  Future<Object?> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;

  /// Runs [code] and streams its output. The stream always ends with a
  /// [DoneChunk]; if the connection drops mid-run it ends with
  /// `DoneChunk(ok: false)`.
  Stream<OutputChunk> execute(String code) {
    final msgId = _newId();
    final controller = StreamController<OutputChunk>();
    final exec = _Execution(controller);
    if (isClosed) {
      controller
        ..add(const ErrorChunk('ConnectionError', 'Runtime disconnected', []))
        ..add(const DoneChunk(ok: false))
        ..close();
      return controller.stream;
    }
    _executions[msgId] = exec;
    _socket.send(
      jsonEncode({
        'header': {
          'msg_id': msgId,
          'msg_type': 'execute_request',
          'username': 'colabmate',
          'session': sessionId,
          'date': DateTime.now().toUtc().toIso8601String(),
          'version': '5.3',
        },
        'parent_header': <String, dynamic>{},
        'metadata': <String, dynamic>{},
        'content': {
          'code': code,
          'silent': false,
          'store_history': true,
          'user_expressions': <String, dynamic>{},
          'allow_stdin': false,
          'stop_on_error': true,
        },
        'channel': 'shell',
        'buffers': <dynamic>[],
      }),
    );
    return controller.stream;
  }

  Future<void> close() async {
    await _socket.close();
    await _sub.cancel();
    _onClosed(null);
  }

  void _onMessage(String raw) {
    final Map<String, dynamic> msg;
    try {
      msg = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return; // Not JSON (e.g. binary protocol frame) — ignore.
    }
    final header = (msg['header'] as Map?) ?? const {};
    final parent = (msg['parent_header'] as Map?) ?? const {};
    final content = (msg['content'] as Map?)?.cast<String, dynamic>() ?? {};
    final type = header['msg_type'];

    if (type == 'status') {
      final state = switch (content['execution_state']) {
        'busy' => KernelStatus.busy,
        'starting' || 'restarting' => KernelStatus.starting,
        'dead' => KernelStatus.disconnected,
        _ => KernelStatus.idle,
      };
      if (state != _lastStatus) {
        _lastStatus = state;
        _status.add(state);
      }
    }

    final exec = _executions[parent['msg_id']];
    if (exec == null) return;
    switch (type) {
      case 'stream':
        exec.add(
          StreamChunk(
            content['name'] as String? ?? 'stdout',
            content['text'] as String? ?? '',
          ),
        );
      case 'execute_result' || 'display_data':
        exec.add(
          RichChunk(
            (content['data'] as Map?)?.cast<String, dynamic>() ?? {},
            executionCount: (content['execution_count'] as num?)?.toInt(),
          ),
        );
      case 'error':
        exec.add(
          ErrorChunk(
            content['ename'] as String? ?? 'Error',
            content['evalue'] as String? ?? '',
            [for (final l in content['traceback'] as List? ?? const []) '$l'],
          ),
        );
      case 'execute_reply':
        exec.replied(
          ok: content['status'] == 'ok',
          count: (content['execution_count'] as num?)?.toInt(),
        );
      case 'status' when content['execution_state'] == 'idle':
        exec.idle();
    }
    if (exec.isDone) _executions.remove(parent['msg_id']);
  }

  void _onClosed(Object? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    _lastStatus = KernelStatus.disconnected;
    _status.add(KernelStatus.disconnected);
    for (final exec in _executions.values) {
      exec.abort();
    }
    _executions.clear();
    unawaited(_status.close());
  }

  static String _newId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Tracks one execute_request until both its execute_reply and the kernel's
/// idle status (sent after all output) have arrived.
class _Execution {
  _Execution(this._out);

  final StreamController<OutputChunk> _out;
  final Stopwatch _clock = Stopwatch()..start();
  bool _replied = false;
  bool _idle = false;
  bool _ok = true;
  int? _count;

  bool get isDone => _out.isClosed;

  void add(OutputChunk chunk) {
    if (!_out.isClosed) _out.add(chunk);
  }

  void replied({required bool ok, int? count}) {
    _replied = true;
    _ok = ok;
    _count = count;
    _maybeFinish();
  }

  void idle() {
    _idle = true;
    _maybeFinish();
  }

  void abort() {
    if (_out.isClosed) return;
    add(const ErrorChunk('ConnectionError', 'Runtime disconnected', []));
    _finish(ok: false);
  }

  void _maybeFinish() {
    if (_replied && _idle) _finish(ok: _ok);
  }

  void _finish({required bool ok}) {
    if (_out.isClosed) return;
    _out.add(
      DoneChunk(ok: ok, executionCount: _count, elapsed: _clock.elapsed),
    );
    unawaited(_out.close());
  }
}
