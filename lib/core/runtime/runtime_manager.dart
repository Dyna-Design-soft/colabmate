import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/output_chunk.dart';
import '../../models/runtime_status.dart';
import 'colab_api.dart';
import 'jupyter_client.dart';
import 'websocket_handler.dart';

typedef JupyterClientFactory = JupyterClient Function(
  Uri baseUrl,
  String Function() token,
);

JupyterClient _defaultJupyter(Uri baseUrl, String Function() token) =>
    JupyterClient(baseUrl: baseUrl, token: token);

/// A connection to a kernel on a Colab runtime (spec §4.3 `RuntimeSession`).
class RuntimeSession {
  RuntimeSession._(this.runtime, this.jupyter, this.kernelId);

  RuntimeInfo runtime;
  final JupyterClient jupyter;
  final String kernelId;
  final String sessionId = _randomId();

  KernelConnection? _connection;
  final _status = StreamController<KernelStatus>.broadcast();
  KernelStatus _lastStatus = KernelStatus.starting;
  bool _disposed = false;
  StreamSubscription<KernelStatus>? _statusSub;

  KernelStatus get status => _lastStatus;

  /// Kernel status changes, including `disconnected` after auto-reconnect
  /// gives up (spec: 3 attempts, 5 s apart).
  Stream<KernelStatus> get statusChanges => _status.stream;

  void _setStatus(KernelStatus s) {
    if (_disposed || s == _lastStatus) return;
    _lastStatus = s;
    _status.add(s);
  }

  static String _randomId() {
    final r = Random();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}

/// Detects Colab runtimes, starts/stops them, connects to kernels, runs
/// cells and streams output (spec §4.3). Built on Google's official Colab
/// API instead of the bridge cell (see docs/SPEC_NOTES.md).
class RuntimeManager {
  RuntimeManager({
    required this._colab,
    this._jupyterFactory = _defaultJupyter,
    this._socketFactory = ioKernelSocket,
    this.reconnectDelay = const Duration(seconds: 5),
    this.reconnectAttempts = 3,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final ColabApi _colab;
  final JupyterClientFactory _jupyterFactory;
  final KernelSocketFactory _socketFactory;
  final DateTime Function() _now;
  final Duration reconnectDelay;
  final int reconnectAttempts;

  ColabApi get colab => _colab;

  /// Runtimes currently assigned to the user.
  Future<List<RuntimeInfo>> listRuntimes() => _colab.listRuntimes();

  /// Starts a new runtime of type [spec] (CPU / T4 GPU / …).
  Future<RuntimeInfo> startRuntime(RuntimeSpecKey spec) =>
      _colab.createRuntime(spec);

  /// Releases a runtime. Anything running on it is lost.
  Future<void> stopRuntime(RuntimeInfo runtime) =>
      _colab.deleteRuntime(runtime.name);

  /// Connects to [runtime]'s Python kernel: reuses the most recently active
  /// kernel (e.g. the one a Colab browser tab is using, so variables are
  /// shared) or starts one.
  Future<RuntimeSession> connectRuntime(RuntimeInfo runtime) async {
    runtime = await _fresh(runtime);
    late RuntimeSession session;
    final jupyter = _jupyterFactory(
      Uri.parse(runtime.connection!.url),
      () => session.runtime.connection!.token,
    );
    // Temporary session object so the token getter works while we look up
    // kernels; the real kernel id is filled in below.
    session = RuntimeSession._(runtime, jupyter, '');
    final kernels = await jupyter.listKernels();
    kernels.sort(
      (a, b) => (b.lastActivity ?? DateTime(0)).compareTo(
        a.lastActivity ?? DateTime(0),
      ),
    );
    final kernel = kernels.isNotEmpty
        ? kernels.first
        : await jupyter.startKernel();
    session = RuntimeSession._(runtime, jupyter, kernel.id);
    await _openSocket(session);
    return session;
  }

  /// Runs [source] on the session's kernel, streaming output. Ends with a
  /// [DoneChunk].
  Stream<OutputChunk> executeCell(RuntimeSession session, String source) {
    final connection = session._connection;
    if (connection == null || connection.isClosed) {
      return Stream.fromIterable(const [
        ErrorChunk('ConnectionError', 'Not connected to a runtime', []),
        DoneChunk(ok: false),
      ]);
    }
    return connection.execute(source);
  }

  KernelStatus getKernelStatus(RuntimeSession session) => session.status;

  /// Stops the running cell.
  Future<void> interrupt(RuntimeSession session) async {
    await _refreshTokenIfNeeded(session);
    await session.jupyter.interruptKernel(session.kernelId);
  }

  /// RAM / disk / GPU usage (FR-03).
  Future<RuntimeResources> getResources(RuntimeSession session) async {
    await _refreshTokenIfNeeded(session);
    return session.jupyter.getResources();
  }

  /// Usage stats for a runtime without connecting to a kernel.
  Future<RuntimeResources> getResourcesFor(RuntimeInfo runtime) async {
    final fresh = await _fresh(runtime);
    return _jupyterFactory(
      Uri.parse(fresh.connection!.url),
      () => fresh.connection!.token,
    ).getResources();
  }

  /// Closes the connection (the runtime keeps running).
  Future<void> disconnectRuntime(RuntimeSession session) async {
    session._disposed = true;
    await session._statusSub?.cancel();
    await session._connection?.close();
    session._connection = null;
    session._lastStatus = KernelStatus.disconnected;
    await session._status.close();
  }

  Future<void> _openSocket(RuntimeSession session) async {
    await _refreshTokenIfNeeded(session);
    final jupyter = session.jupyter;
    final connection = await KernelConnection.open(
      jupyter.channelsUri(session.kernelId, sessionId: session.sessionId),
      jupyter.headers,
      sessionId: session.sessionId,
      socketFactory: _socketFactory,
    );
    session._connection = connection;
    await session._statusSub?.cancel();
    session._statusSub = connection.statusChanges.listen((s) {
      if (s != KernelStatus.disconnected) session._setStatus(s);
    });
    session._setStatus(
      connection.status == KernelStatus.disconnected
          ? KernelStatus.idle
          : connection.status,
    );
    unawaited(connection.closed.then((_) => _onDropped(session, connection)));
  }

  /// Auto-reconnect (spec §4.3): retry every [reconnectDelay], up to
  /// [reconnectAttempts] times, then report `disconnected`.
  Future<void> _onDropped(
    RuntimeSession session,
    KernelConnection dropped,
  ) async {
    if (session._disposed || !identical(session._connection, dropped)) return;
    session._setStatus(KernelStatus.starting);
    for (var attempt = 1; attempt <= reconnectAttempts; attempt++) {
      await Future<void>.delayed(reconnectDelay);
      if (session._disposed) return;
      try {
        await _openSocket(session);
        return;
      } catch (e) {
        debugPrint('RuntimeManager: reconnect $attempt failed: $e');
      }
    }
    session._connection = null;
    session._setStatus(KernelStatus.disconnected);
  }

  /// Fetches connection info if missing or about to expire.
  Future<RuntimeInfo> _fresh(RuntimeInfo runtime) async {
    final conn = runtime.connection;
    final expiry = conn?.expireTime;
    // Unknown expiry → treat as stale; the proxy token is short-lived.
    final stale =
        conn == null ||
        conn.url.isEmpty ||
        expiry == null ||
        !_now().add(const Duration(minutes: 5)).isBefore(expiry);
    if (!stale) return runtime;
    final fresh = await _colab.getRuntime(runtime.name);
    if (fresh.connection == null || fresh.connection!.url.isEmpty) {
      throw const ColabApiException(
        'This runtime is not ready yet. Try again in a moment.',
      );
    }
    return fresh;
  }

  Future<void> _refreshTokenIfNeeded(RuntimeSession session) async {
    session.runtime = await _fresh(session.runtime);
  }
}
