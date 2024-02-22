import 'dart:async';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sql_crdt/sql_crdt.dart';

class ExecutorApi extends DatabaseApi {
  final DatabaseExecutor _db;

  ExecutorApi(this._db);

  @override
  Future<void> execute(String sql, [List<Object?>? args]) =>
      _db.execute(sql, args);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?>? args]) =>
      _db.rawQuery(sql, args);

  @override
  Future<void> transaction(Future<void> Function(ReadWriteApi api) actions) {
    assert(_db is Database, 'Cannot start a transaction within a transaction');
    return (_db as Database).transaction((t) => actions(ExecutorApi(t)));
  }

  @override
  Future<void> executeBatch(
      FutureOr<void> Function(WriteApi api) actions) async {
    final batch = _db.batch();
    actions(BatchApi(batch));
    await batch.commit();
  }
}

/// Simplified wrapper intended for Sqlite batches.
class BatchApi extends WriteApi {
  final Batch _batch;

  BatchApi(this._batch);

  void query(String sql, [List<Object?>? args]) => _batch.rawQuery(sql, args);

  @override
  void execute(String sql, [List<Object?>? args]) => _batch.execute(sql, args);
}
