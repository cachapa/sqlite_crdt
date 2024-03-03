import 'package:sqflite_common/sqlite_api.dart';
import 'package:sql_crdt/sql_crdt.dart';
import 'package:sqlite_crdt/src/sqlite_api.dart';

/// Wrapper around Sqlite batches that automatically applies CRDT metadata to
/// inserted records.
///
/// Note that timestamps are fixed at the moment of instantiation, so creating
/// long-lived batches is discouraged.
class BatchExecutor extends CrdtWriteExecutor {
  final Batch _batch;

  BatchExecutor(this._batch, Hlc hlc) : super(BatchApi(_batch), hlc);

  /// Commit this batch atomically. See Sqlite documentation for details.
  Future<List<Object?>> commit() => _batch.commit();
}
