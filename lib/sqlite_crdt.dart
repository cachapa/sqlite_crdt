library sqlite_crdt;

import 'dart:async';

// ignore: implementation_imports
import 'package:sqflite_common/src/open_options.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sql_crdt/sql_crdt.dart';
import 'package:sqlite_crdt/src/sqlite_api.dart';

import 'src/is_web_locator.dart';

export 'package:sqflite_common/sqlite_api.dart';
export 'package:sql_crdt/sql_crdt.dart';
export 'src/serializable.dart';

class SqliteCrdt extends SqlCrdt {
  SqliteCrdt._(super.db);

  /// Open or create a SQLite container as a SqlCrdt instance.
  ///
  /// See the Sqflite documentation for more details on opening a database:
  /// https://github.com/tekartik/sqflite/blob/master/sqflite/doc/opening_db.md
  static Future<SqliteCrdt> open(
    String path, {
    bool singleInstance = true,
    int? version,
    FutureOr<void> Function(BaseCrdt crdt, int version)? onCreate,
    FutureOr<void> Function(BaseCrdt crdt, int from, int to)? onUpgrade,
    bool migrate = false,
  }) =>
      _open(path, false, singleInstance, version, onCreate, onUpgrade, migrate: migrate);

  /// Open a transient SQLite in memory.
  /// Useful for testing or temporary sessions.
  static Future<SqliteCrdt> openInMemory({
    bool singleInstance = false,
    int? version,
    FutureOr<void> Function(BaseCrdt crdt, int version)? onCreate,
    FutureOr<void> Function(BaseCrdt crdt, int from, int to)? onUpgrade,
    bool migrate = false,
  }) =>
      _open(null, true, singleInstance, version, onCreate, onUpgrade, migrate: migrate);

  static Future<SqliteCrdt> _open(
    String? path,
    bool inMemory,
    bool singleInstance,
    int? version,
    FutureOr<void> Function(BaseCrdt crdt, int version)? onCreate,
    FutureOr<void> Function(BaseCrdt crdt, int from, int to)? onUpgrade,
    {bool migrate = false}
  ) async {
    if (sqliteCrdtIsWeb && !inMemory && path!.contains('/')) {
      path = path.substring(path.lastIndexOf('/') + 1);
    }
    assert(inMemory || path!.isNotEmpty);
    final databaseFactory =
        sqliteCrdtIsWeb ? databaseFactoryFfiWeb : databaseFactoryFfi;

    if (!sqliteCrdtIsWeb && sqliteCrdtIsLinux) {
      await databaseFactory.setDatabasesPath('.');
    }

    final db = await databaseFactory.openDatabase(
      inMemory ? inMemoryDatabasePath : path!,
      options: SqfliteOpenDatabaseOptions(
        singleInstance: singleInstance,
        version: version,
        onCreate: onCreate == null
            ? null
            : (db, version) => onCreate.call(BaseCrdt(SqliteApi(db)), version),
        onUpgrade: onUpgrade == null
            ? null
            : (db, from, to) =>
                onUpgrade.call(BaseCrdt(SqliteApi(db)), from, to),
      ),
    );

    final crdt = SqliteCrdt._(SqliteApi(db));
    try {
      await crdt.init();
    } on DatabaseException catch (e) {
      // ignore
      final err = e.toString();
      if (e.getResultCode() == 1 && err.contains('no such column: modified') && migrate) {
        await crdt.migrate();
      } else {
        rethrow;
      }
    }
    return crdt;
  }

  @override
  Future<void> close() async {
    return databaseApi.close();
  }

  Batch batch() => (databaseApi as Database).batch();
}
