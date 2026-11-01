import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/notebook.dart';
import '../auth/auth_exceptions.dart';
import '../auth/auth_manager.dart';
import 'notebook_cache.dart';

/// Drive is unreachable (no network). Callers fall back to the cache.
class DriveOfflineException implements Exception {
  const DriveOfflineException();
  @override
  String toString() => 'You are offline.';
}

/// The notebook isn't in Drive (deleted / no access) and not cached.
class NotebookNotFoundException implements Exception {
  const NotebookNotFoundException(this.id);
  final String id;
  @override
  String toString() => 'Notebook not found.';
}

/// Any other Drive API failure.
class DriveApiException implements Exception {
  const DriveApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Result of [DriveManager.listNotebooks].
@immutable
class NotebookListing {
  const NotebookListing(this.notebooks, {required this.fromCache});
  final List<NotebookMeta> notebooks;

  /// True when Drive was unreachable and the cached list was returned.
  final bool fromCache;
}

/// Outcome of uploading one pending notebook in [DriveManager.syncPending].
@immutable
class SyncResult {
  const SyncResult(this.id, this.name, {this.error});
  final String id;
  final String name;
  final Object? error;
  bool get ok => error == null;
}

/// Lists, reads, writes and caches Google Drive notebooks (spec §4.2).
///
/// Conflict rule: local edits always win (last write wins, no merge).
class DriveManager {
  DriveManager({
    required AuthManager auth,
    required this._cache,
    Dio? dio,
    DateTime Function()? clock,
  }) : _auth = auth,
       _now = clock ?? DateTime.now,
       _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout ??= const Duration(seconds: 10)
      ..receiveTimeout ??= const Duration(seconds: 30);
    _dio.interceptors.add(_AuthInterceptor(auth, _dio));
  }

  static const String _api = 'https://www.googleapis.com/drive/v3/files';
  static const String _upload =
      'https://www.googleapis.com/upload/drive/v3/files';
  static const String colabMimeType = 'application/vnd.google.colaboratory';

  final AuthManager _auth;
  final NotebookCache _cache;
  final DateTime Function() _now;
  final Dio _dio;

  Future<void>? _syncing;

  AuthManager get auth => _auth;

  /// All .ipynb notebooks in the user's Drive, newest first. Falls back to
  /// the cached list when offline.
  Future<NotebookListing> listNotebooks() async {
    try {
      final items = <NotebookMeta>[];
      String? pageToken;
      do {
        final res = await _dio.get<Map<String, dynamic>>(
          _api,
          queryParameters: {
            'q':
                "trashed = false and (mimeType = '$colabMimeType' "
                "or name contains '.ipynb')",
            'fields': 'nextPageToken, files(id, name, mimeType, modifiedTime)',
            'orderBy': 'modifiedTime desc',
            'pageSize': 200,
            'spaces': 'drive',
            'pageToken': ?pageToken,
          },
        );
        final data = res.data ?? const {};
        for (final f in (data['files'] as List? ?? const []).cast<Map>()) {
          final name = f['name'] as String? ?? '';
          final mime = f['mimeType'] as String?;
          // `contains` is a prefix/word match in Drive, so double-check.
          if (mime != colabMimeType && !name.toLowerCase().endsWith('.ipynb')) {
            continue;
          }
          items.add(
            NotebookMeta(
              id: f['id'] as String,
              name: name,
              mimeType: mime,
              modifiedTime: DateTime.tryParse(
                f['modifiedTime'] as String? ?? '',
              ),
            ),
          );
        }
        pageToken = data['nextPageToken'] as String?;
      } while (pageToken != null && items.length < 2000);

      await _cache.replaceListing(items);
      // Re-read so pending-sync flags from local edits are included.
      return NotebookListing(await _cache.listMeta(), fromCache: false);
    } on DioException catch (e) {
      final mapped = _map(e);
      if (mapped is DriveOfflineException) {
        return NotebookListing(await _cache.listMeta(), fromCache: true);
      }
      throw mapped;
    }
  }

  /// Opens a notebook. Local unsynced edits win over Drive; otherwise the
  /// latest Drive version is downloaded and cached. Offline → cached copy.
  Future<Notebook> readNotebook(String id) async {
    final cached = await _cache.get(id);
    if (cached != null && cached.pendingSync) {
      // Local edit always wins; try to push it in the background.
      unawaited(syncPending().catchError((_) => <SyncResult>[]));
      return cached;
    }
    try {
      final responses = await Future.wait([
        _dio.get<Map<String, dynamic>>(
          '$_api/$id',
          queryParameters: {'fields': 'id, name, mimeType, modifiedTime'},
        ),
        _dio.get<String>(
          '$_api/$id',
          queryParameters: {'alt': 'media'},
          options: Options(responseType: ResponseType.plain),
        ),
      ]);
      final meta = responses[0].data as Map<String, dynamic>;
      final notebook = Notebook.fromIpynb(
        id: id,
        name: meta['name'] as String? ?? cached?.name ?? 'Untitled.ipynb',
        mimeType: meta['mimeType'] as String?,
        json: responses[1].data as String,
      );
      await _cache.putSynced(
        notebook,
        syncedAt: _now(),
        modifiedTime: DateTime.tryParse(meta['modifiedTime'] as String? ?? ''),
      );
      return notebook;
    } on DioException catch (e) {
      final mapped = _map(e, id: id);
      if (mapped is DriveOfflineException && cached != null) return cached;
      throw mapped;
    }
  }

  /// Saves [notebook]: always written to the cache first, then uploaded.
  /// Offline, it stays queued (`pendingSync`) and the returned copy says so.
  Future<Notebook> saveNotebook(Notebook notebook) async {
    final pending = notebook.copyWith(pendingSync: true);
    await _cache.putPending(pending);
    try {
      await _uploadAndMark(pending);
      return notebook.copyWith(pendingSync: false);
    } on DriveOfflineException {
      return pending;
    }
  }

  /// Uploads every notebook with local edits. Concurrent calls share one run.
  /// Partial failures are reported per file.
  Future<List<SyncResult>> syncPending() async {
    while (_syncing != null) {
      await _syncing;
    }
    final done = Completer<void>();
    _syncing = done.future;
    try {
      final results = <SyncResult>[];
      for (final nb in await _cache.pending()) {
        try {
          await _uploadAndMark(nb);
          results.add(SyncResult(nb.id, nb.name));
        } on DriveOfflineException catch (e) {
          results.add(SyncResult(nb.id, nb.name, error: e));
          break; // No point trying the rest.
        } catch (e) {
          debugPrint('DriveManager: sync of ${nb.name} failed: $e');
          results.add(SyncResult(nb.id, nb.name, error: e));
        }
      }
      return results;
    } finally {
      _syncing = null;
      done.complete();
    }
  }

  /// Cached copy (with content) or null if never opened.
  Future<Notebook?> getCachedNotebook(String id) => _cache.get(id);

  Future<void> _uploadAndMark(Notebook notebook) async {
    final content = notebook.toIpynb();
    try {
      await _dio.patch<Object>(
        '$_upload/${notebook.id}',
        queryParameters: {'uploadType': 'media'},
        data: content,
        options: Options(
          // Keep the original type so Colab still opens the file.
          contentType: notebook.mimeType ?? colabMimeType,
        ),
      );
    } on DioException catch (e) {
      throw _map(e, id: notebook.id);
    }
    await _cache.markSynced(
      notebook.id,
      uploadedContent: content,
      syncedAt: _now(),
    );
  }

  Exception _map(DioException e, {String? id}) {
    // Token problems from the interceptor: offline vs. must sign in again.
    final cause = e.error;
    if (cause is AuthNetworkException) return const DriveOfflineException();
    if (cause is AuthException) return cause;
    final res = e.response;
    if (res == null) return const DriveOfflineException();
    final status = res.statusCode;
    if (status == 404 && id != null) return NotebookNotFoundException(id);
    final data = res.data;
    final message = data is Map && data['error'] is Map
        ? (data['error'] as Map)['message']
        : null;
    if (status == 403 && '$message'.contains('Drive API has not been used')) {
      return const DriveApiException(
        'Google Drive API is not enabled for this Google Cloud project.',
      );
    }
    return DriveApiException('Google Drive error $status: ${message ?? data}');
  }
}

/// Adds `Authorization: Bearer <token>` and retries once after a 401 with a
/// freshly refreshed token. (AuthManager already de-duplicates concurrent
/// refreshes, so a plain — non-queued — interceptor is enough and can't
/// deadlock when the retried request fails too.)
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._auth, this._dio);

  final AuthManager _auth;
  final Dio _dio;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      final token = await _auth.getAccessToken();
      options.headers['Authorization'] = 'Bearer $token';
      handler.next(options);
    } catch (e) {
      handler.reject(DioException(requestOptions: options, error: e));
    }
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 || options.extra['retried'] == true) {
      return handler.next(err);
    }
    try {
      final token = await _auth.refreshAccessToken();
      options
        ..headers['Authorization'] = 'Bearer $token'
        ..extra['retried'] = true;
      handler.resolve(await _dio.fetch<Object?>(options));
    } on DioException catch (e) {
      handler.next(e);
    } catch (e) {
      // Refresh failed (e.g. access revoked → AuthExpiredException): report
      // that, not the original 401, so the app can ask to sign in again.
      handler.next(
        DioException(requestOptions: options, response: err.response, error: e),
      );
    }
  }
}
