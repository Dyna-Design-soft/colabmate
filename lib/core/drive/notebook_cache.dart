import 'package:drift/drift.dart';

import '../../db/database.dart';
import '../../models/notebook.dart';

/// SQLite cache of Drive notebooks (spec §4.2 "Offline Strategy").
class NotebookCache {
  NotebookCache(this._db);

  final AppDatabase _db;

  /// All known notebooks, most recently modified first.
  Future<List<NotebookMeta>> listMeta() async {
    final rows =
        await (_db.select(_db.notebooks)..orderBy([
              (t) => OrderingTerm.desc(t.modifiedTime),
              (t) => OrderingTerm.asc(t.name),
            ]))
            .get();
    return rows.map(_meta).toList();
  }

  /// Replaces the cached listing with [items] from Drive. Content already
  /// downloaded is kept; notebooks gone from Drive are dropped unless they
  /// have unsynced local edits.
  Future<void> replaceListing(List<NotebookMeta> items) =>
      _db.transaction(() async {
        final ids = items.map((m) => m.id).toSet();
        await (_db.delete(
          _db.notebooks,
        )..where((t) => t.id.isNotIn(ids) & t.pendingSync.equals(false))).go();
        for (final m in items) {
          await _db
              .into(_db.notebooks)
              .insert(
                NotebooksCompanion.insert(
                  id: m.id,
                  name: m.name,
                  mimeType: Value(m.mimeType),
                  modifiedTime: Value(m.modifiedTime),
                ),
                onConflict: DoUpdate(
                  (_) => NotebooksCompanion(
                    name: Value(m.name),
                    mimeType: Value(m.mimeType),
                    modifiedTime: Value(m.modifiedTime),
                  ),
                ),
              );
        }
      });

  /// Cached notebook with content, or null if it was never opened.
  Future<Notebook?> get(String id) async {
    final row = await (_db.select(
      _db.notebooks,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final content = row?.content;
    if (row == null || content == null) return null;
    return Notebook.fromIpynb(
      id: row.id,
      name: row.name,
      json: content,
      mimeType: row.mimeType,
      pendingSync: row.pendingSync,
    );
  }

  /// Stores [notebook] as downloaded from / uploaded to Drive at [syncedAt].
  Future<void> putSynced(
    Notebook notebook, {
    required DateTime syncedAt,
    DateTime? modifiedTime,
  }) => _put(
    notebook,
    pendingSync: false,
    lastSynced: Value(syncedAt),
    modifiedTime: modifiedTime,
  );

  /// Stores a local edit that still has to be uploaded.
  Future<void> putPending(Notebook notebook) =>
      _put(notebook, pendingSync: true, lastSynced: const Value.absent());

  /// Clears the pending flag after a successful upload — but only if the
  /// content wasn't edited again while the upload was running.
  Future<void> markSynced(
    String id, {
    required String uploadedContent,
    required DateTime syncedAt,
  }) =>
      (_db.update(_db.notebooks)
            ..where((t) => t.id.equals(id) & t.content.equals(uploadedContent)))
          .write(
            NotebooksCompanion(
              pendingSync: const Value(false),
              lastSynced: Value(syncedAt),
            ),
          );

  /// Notebooks with local edits waiting to be uploaded.
  Future<List<Notebook>> pending() async {
    final rows = await (_db.select(
      _db.notebooks,
    )..where((t) => t.pendingSync.equals(true))).get();
    return [
      for (final r in rows)
        if (r.content != null)
          Notebook.fromIpynb(
            id: r.id,
            name: r.name,
            json: r.content!,
            mimeType: r.mimeType,
            pendingSync: true,
          ),
    ];
  }

  Future<void> clear() => _db.delete(_db.notebooks).go();

  Future<void> _put(
    Notebook notebook, {
    required bool pendingSync,
    required Value<DateTime> lastSynced,
    DateTime? modifiedTime,
  }) {
    final row = NotebooksCompanion(
      id: Value(notebook.id),
      name: Value(notebook.name),
      mimeType: Value(notebook.mimeType),
      content: Value(notebook.toIpynb()),
      pendingSync: Value(pendingSync),
      lastSynced: lastSynced,
      modifiedTime: modifiedTime == null
          ? const Value.absent()
          : Value(modifiedTime),
    );
    return _db
        .into(_db.notebooks)
        .insert(row, onConflict: DoUpdate((_) => row));
  }

  NotebookMeta _meta(NotebookRow r) => NotebookMeta(
    id: r.id,
    name: r.name,
    modifiedTime: r.modifiedTime,
    mimeType: r.mimeType,
    pendingSync: r.pendingSync,
  );
}
