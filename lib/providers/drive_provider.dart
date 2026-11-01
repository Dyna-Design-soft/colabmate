import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/auth/auth_exceptions.dart';
import '../core/drive/drive_manager.dart';
import '../core/drive/notebook_cache.dart';
import '../db/database.dart';
import '../models/notebook.dart';
import 'auth_provider.dart';

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final notebookCacheProvider = Provider<NotebookCache>(
  (ref) => NotebookCache(ref.watch(appDatabaseProvider)),
);

final driveManagerProvider = Provider<DriveManager>(
  (ref) => DriveManager(
    auth: ref.watch(authManagerProvider),
    cache: ref.watch(notebookCacheProvider),
  ),
);

/// The notebook list (Drive, or the cache when offline).
final notebookListProvider =
    AsyncNotifierProvider<NotebookListController, NotebookListing>(
      NotebookListController.new,
      retry: (_, _) => null,
    );

class NotebookListController extends AsyncNotifier<NotebookListing> {
  @override
  Future<NotebookListing> build() =>
      _signOutIfExpired(ref, ref.read(driveManagerProvider).listNotebooks());

  /// Pull-to-refresh: re-lists without dropping the current list meanwhile.
  Future<void> refresh() async {
    ref.invalidateSelf();
    await future.catchError((_) => const NotebookListing([], fromCache: true));
  }
}

/// One opened notebook, by Drive file id.
final notebookProvider =
    AsyncNotifierProvider.family<NotebookController, Notebook, String>(
      NotebookController.new,
      retry: (_, _) => null,
    );

class NotebookController extends AsyncNotifier<Notebook> {
  NotebookController(this.id);
  final String id;

  DriveManager get _drive => ref.read(driveManagerProvider);

  @override
  Future<Notebook> build() => _signOutIfExpired(ref, _drive.readNotebook(id));

  /// Edits one cell and saves (offline → queued). Returns null on success or
  /// the error if the upload failed for a reason other than being offline;
  /// the edit is kept locally either way.
  Future<Object?> saveCell(int index, String source) async {
    final current = state.value;
    if (current == null) return StateError('Notebook not loaded');
    final edited = current.updateCell(index, source);
    state = AsyncData(edited.copyWith(pendingSync: true));
    try {
      state = AsyncData(await _drive.saveNotebook(edited));
      return null;
    } catch (e) {
      return e;
    } finally {
      ref.invalidate(notebookListProvider);
    }
  }
}

/// If Google rejected the session (expired / revoked, test A6), send the app
/// back to the sign-in screen instead of just showing an error.
Future<T> _signOutIfExpired<T>(Ref ref, Future<T> call) async {
  try {
    return await call;
  } on AuthExpiredException {
    ref.invalidate(authControllerProvider);
    rethrow;
  } on NotSignedInException {
    ref.invalidate(authControllerProvider);
    rethrow;
  }
}

/// Sync status shown in the app bar.
@immutable
class SyncState {
  const SyncState({this.syncing = false, this.online = true, this.failed = 0});
  final bool syncing;
  final bool online;

  /// Notebooks that failed to upload in the last sync run.
  final int failed;
}

/// Uploads pending offline edits on start-up and whenever the network comes
/// back (spec §3 "Data Flow — Offline Edit + Sync", FR-06).
final syncControllerProvider = NotifierProvider<SyncController, SyncState>(
  SyncController.new,
);

class SyncController extends Notifier<SyncState> {
  StreamSubscription<List<ConnectivityResult>>? _sub;

  @override
  SyncState build() {
    _sub = Connectivity().onConnectivityChanged.listen(_onConnectivity);
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(syncNow);
    return const SyncState();
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    final wasOnline = state.online;
    state = SyncState(
      syncing: state.syncing,
      online: online,
      failed: state.failed,
    );
    if (online && !wasOnline) {
      // Give the new connection a moment to come up properly.
      Future.delayed(const Duration(seconds: 2), syncNow);
    }
  }

  Future<void> syncNow() async {
    if (!ref.mounted || state.syncing) return;
    state = SyncState(
      syncing: true,
      online: state.online,
      failed: state.failed,
    );
    var failed = 0;
    var uploaded = 0;
    try {
      final results = await ref.read(driveManagerProvider).syncPending();
      failed = results.where((r) => !r.ok).length;
      uploaded = results.length - failed;
    } catch (e) {
      debugPrint('SyncController: $e');
    }
    if (!ref.mounted) return;
    state = SyncState(online: state.online, failed: failed);
    if (uploaded > 0) {
      ref
        ..invalidate(notebookListProvider)
        ..invalidate(notebookProvider);
    }
  }
}

/// Signs out and clears the notebook cache (so another account never sees
/// this account's notebooks). Unsynced edits are lost — the UI confirms
/// first using [pendingEditCount].
Future<void> signOutAndClearCache(WidgetRef ref) async {
  await ref.read(authControllerProvider.notifier).signOut();
  await ref.read(notebookCacheProvider).clear();
  ref.invalidate(notebookListProvider);
  ref.invalidate(notebookProvider);
}

Future<int> pendingEditCount(WidgetRef ref) async =>
    (await ref.read(notebookCacheProvider).pending()).length;
