import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables/notebooks_table.dart';

part 'database.g.dart';

@DriftDatabase(tables: [Notebooks])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
    : super(executor ?? driftDatabase(name: 'colabmate'));

  @override
  int get schemaVersion => 1;
}
