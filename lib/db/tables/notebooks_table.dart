import 'package:drift/drift.dart';

/// Cached Drive notebooks (spec §3 "Local SQLite"). A row exists for every
/// notebook seen in a Drive listing; [content] is filled once it's opened.
@DataClassName('NotebookRow')
class Notebooks extends Table {
  /// Google Drive file id.
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get mimeType => text().nullable()();

  /// Drive's modifiedTime at the last listing.
  DateTimeColumn get modifiedTime => dateTime().nullable()();

  /// Raw .ipynb JSON; null until the notebook has been opened once.
  TextColumn get content => text().nullable()();

  /// When [content] was last downloaded from / uploaded to Drive.
  DateTimeColumn get lastSynced => dateTime().nullable()();

  /// Local edits not yet uploaded to Drive (spec §4.2 offline strategy).
  BoolColumn get pendingSync => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}
