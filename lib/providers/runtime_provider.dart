import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_exceptions.dart';
import '../core/runtime/colab_api.dart';
import '../core/runtime/runtime_manager.dart';
import '../models/output_chunk.dart';
import '../models/runtime_status.dart';
import 'auth_provider.dart';

final colabApiProvider = Provider<ColabApi>(
  (ref) => ColabApi(auth: ref.watch(authManagerProvider)),
);

/// What the Colab screen shows.
@immutable
class ColabOverview {
  const ColabOverview({
    this.needsGrant = false,
    this.tier = SubscriptionTier.unknown,
    this.specs = const [],
    this.runtimes = const [],
  });

  /// Colab access hasn't been granted yet — show the "Allow" button.
  final bool needsGrant;
  final SubscriptionTier tier;
  final List<RuntimeSpecOption> specs;
  final List<RuntimeInfo> runtimes;
}

final colabOverviewProvider =
    AsyncNotifierProvider<ColabOverviewController, ColabOverview>(
      ColabOverviewController.new,
      retry: (_, _) => null,
    );

class ColabOverviewController extends AsyncNotifier<ColabOverview> {
  ColabApi get _api => ref.read(colabApiProvider);

  @override
  Future<ColabOverview> build() async {
    try {
      final results = await Future.wait([
        _api.getSubscription(),
        _api.listRuntimeSpecs(),
        _api.listRuntimes(),
      ]);
      return ColabOverview(
        tier: results[0] as SubscriptionTier,
        specs: results[1] as List<RuntimeSpecOption>,
        runtimes: results[2] as List<RuntimeInfo>,
      );
    } on ScopeNotGrantedException {
      return const ColabOverview(needsGrant: true);
    }
  }

  /// Shows Google's consent screen for Colab access, then reloads.
  Future<void> grantAndLoad() async {
    state = const AsyncLoading();
    try {
      await _api.grantAccess();
    } catch (e, st) {
      state = AsyncError(e, st);
      return;
    }
    ref.invalidateSelf();
    await future.catchError((_) => const ColabOverview());
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future.catchError((_) => const ColabOverview());
  }
}

// ---------------------------------------------------------------------------
// Runtime connection + cell execution (Phase 4 step 2)
// ---------------------------------------------------------------------------

final runtimeManagerProvider = Provider<RuntimeManager>(
  (ref) => RuntimeManager(colab: ref.watch(colabApiProvider)),
);

/// The runtime/kernel the app is connected to (one at a time).
@immutable
class SessionState {
  const SessionState({
    this.session,
    this.status = KernelStatus.disconnected,
    this.busyMessage,
    this.error,
  });

  final RuntimeSession? session;
  final KernelStatus status;

  /// Non-null while starting / connecting / stopping ("Starting T4 GPU…").
  final String? busyMessage;
  final Object? error;

  bool get connected => session != null && status != KernelStatus.disconnected;
  RuntimeInfo? get runtime => session?.runtime;
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

class SessionController extends Notifier<SessionState> {
  StreamSubscription<KernelStatus>? _statusSub;

  RuntimeManager get _manager => ref.read(runtimeManagerProvider);

  @override
  SessionState build() {
    ref.onDispose(() {
      _statusSub?.cancel();
      final s = state.session;
      if (s != null) unawaited(_manager.disconnectRuntime(s));
    });
    return const SessionState();
  }

  /// Connects to an existing runtime.
  Future<void> connect(RuntimeInfo runtime) =>
      _guard('Connecting to ${runtime.spec.label}…', () async {
        await _closeCurrent();
        _attach(await _manager.connectRuntime(runtime));
      });

  /// Starts a new runtime of [spec] and connects to it.
  Future<void> startAndConnect(RuntimeSpecKey spec) =>
      _guard('Starting ${spec.label}… this can take a minute', () async {
        await _closeCurrent();
        final runtime = await _manager.startRuntime(spec);
        ref.invalidate(colabOverviewProvider);
        _attach(await _manager.connectRuntime(runtime));
      });

  /// Releases a runtime (disconnecting first if it's the connected one).
  Future<void> stop(RuntimeInfo runtime) =>
      _guard('Stopping ${runtime.spec.label}…', () async {
        if (state.runtime?.name == runtime.name) await _closeCurrent();
        await _manager.stopRuntime(runtime);
        ref.invalidate(colabOverviewProvider);
      });

  Future<void> disconnect() async {
    await _closeCurrent();
    state = const SessionState();
  }

  void _attach(RuntimeSession session) {
    _statusSub?.cancel();
    _statusSub = session.statusChanges.listen((s) {
      state = SessionState(session: session, status: s);
    });
    state = SessionState(session: session, status: session.status);
  }

  Future<void> _closeCurrent() async {
    await _statusSub?.cancel();
    _statusSub = null;
    final s = state.session;
    if (s != null) await _manager.disconnectRuntime(s);
  }

  Future<void> _guard(String message, Future<void> Function() body) async {
    state = SessionState(
      session: state.session,
      status: state.status,
      busyMessage: message,
    );
    try {
      await body();
      if (state.busyMessage != null) {
        state = SessionState(session: state.session, status: state.status);
      }
    } catch (e) {
      debugPrint('SessionController: $e');
      state = SessionState(
        session: state.session,
        status: state.session?.status ?? KernelStatus.disconnected,
        error: e,
      );
    }
  }
}

/// Live RAM / GPU / disk for a runtime, refreshed every 5 s while watched
/// (FR-03, test R6).
final runtimeResourcesProvider = StreamProvider.autoDispose
    .family<RuntimeResources, String>((ref, runtimeName) async* {
      final manager = ref.read(runtimeManagerProvider);
      RuntimeInfo? runtime() {
        final s = ref.read(sessionControllerProvider).session;
        if (s != null && s.runtime.name == runtimeName) return s.runtime;
        return ref
            .read(colabOverviewProvider)
            .value
            ?.runtimes
            .where((r) => r.name == runtimeName)
            .firstOrNull;
      }

      while (true) {
        final r = runtime();
        if (r == null) return;
        try {
          yield await manager.getResourcesFor(r);
        } catch (e) {
          debugPrint('resources($runtimeName): $e');
        }
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    });

/// Compute-unit usage, if Colab exposes it to this app (else null).
final colabUsageProvider = FutureProvider.autoDispose<ColabUsage?>(
  (ref) => ref.read(colabApiProvider).getUsage(),
);

/// Output of one cell run.
@immutable
class CellRun {
  const CellRun({this.chunks = const [], this.running = true});

  final List<OutputChunk> chunks;
  final bool running;

  DoneChunk? get done => chunks.whereType<DoneChunk>().firstOrNull;
  bool get failed =>
      chunks.any((c) => c is ErrorChunk) || (done != null && !done!.ok);
}

/// Live cell outputs for one notebook (keyed by cell index).
final cellRunsProvider =
    NotifierProvider.family<CellRunsController, Map<int, CellRun>, String>(
      CellRunsController.new,
    );

class CellRunsController extends Notifier<Map<int, CellRun>> {
  CellRunsController(this.notebookId);
  final String notebookId;
  final Map<int, StreamSubscription<OutputChunk>> _subs = {};

  @override
  Map<int, CellRun> build() {
    ref.onDispose(() {
      for (final s in _subs.values) {
        s.cancel();
      }
    });
    return const {};
  }

  /// Runs a cell on the connected runtime and streams its output.
  /// Returns false if no runtime is connected.
  bool run(int index, String source) {
    final session = ref.read(sessionControllerProvider).session;
    if (session == null) return false;
    _subs.remove(index)?.cancel();
    _update(index, const CellRun());
    final chunks = <OutputChunk>[];
    _subs[index] = ref
        .read(runtimeManagerProvider)
        .executeCell(session, source)
        .listen(
          (chunk) {
            chunks.add(chunk);
            _update(
              index,
              CellRun(chunks: List.of(chunks), running: chunk is! DoneChunk),
            );
          },
          onDone: () {
            _subs.remove(index);
            if (state[index]?.running ?? false) {
              _update(index, CellRun(chunks: List.of(chunks), running: false));
            }
          },
        );
    return true;
  }

  Future<void> interrupt() async {
    final session = ref.read(sessionControllerProvider).session;
    if (session != null) {
      await ref.read(runtimeManagerProvider).interrupt(session);
    }
  }

  void _update(int index, CellRun run) => state = {...state, index: run};
}
