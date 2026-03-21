import 'dart:async';

import 'package:crdt/crdt.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqlite_crdt/src/crdt_executor.dart';
import 'package:sqlite_crdt/src/sql_util.dart';
import 'package:uuid/uuid.dart';

import 'src/is_web_locator.dart';

export 'package:crdt/crdt.dart';
export 'package:sqflite_common/sqlite_api.dart';
export 'package:sqlite_crdt/src/crdt_executor.dart';

/// Convenience method to generate a node id based on UUID V4
String generateNodeId() => const Uuid().v4();

typedef Result = List<Map<String, Object?>>;
typedef OnCreate = Future<void> Function(Database db, int version);
typedef OnUpgrade = Future<void> Function(Database db, int from, int to);

class SqliteCrdt extends Crdt {
  final String crdtTable;
  final Database _db;
  final Map<String, Iterable<String>> _tableIndexes;

  final _watches = <StreamController<Result>, Query>{};

  @override
  Iterable<String> get collections => tables;
  Iterable<String> get tables => _tableIndexes.keys;

  @override
  int get canonicalTime => _canonicalTime;
  int _canonicalTime;

  SqliteCrdt._(
    super.nodeId,
    this._canonicalTime,
    this.crdtTable,
    this._db,
    this._tableIndexes,
  ) : assert(crdtTable.isNotEmpty),
      assert(_tableIndexes.isNotEmpty);

  /// Open or create a SQLite container as a SqlCrdt instance.
  ///
  /// See the Sqflite documentation for more details on opening a database:
  /// https://github.com/tekartik/sqflite/blob/master/sqflite/doc/opening_db.md
  static Future<SqliteCrdt> open(
    String path, {
    bool singleInstance = true,
    int version = 1,
    String crdtTablesPrefix = 'crdt',
    required Iterable<String> collections,
    required OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  }) => _open(
    path,
    false,
    singleInstance,
    version,
    crdtTablesPrefix,
    collections,
    onCreate,
    onUpgrade,
  );

  /// Open a transient SQLite in memory.
  /// Useful for testing or temporary sessions.
  static Future<SqliteCrdt> openInMemory({
    bool singleInstance = false,
    int version = 1,
    String crdtTablesPrefix = 'crdt',
    required Iterable<String> collections,
    OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  }) => _open(
    null,
    true,
    singleInstance,
    version,
    crdtTablesPrefix,
    collections,
    onCreate,
    onUpgrade,
  );

  static Future<SqliteCrdt> _open(
    String? path,
    bool inMemory,
    bool singleInstance,
    int version,
    String crdtTable,
    Iterable<String> collections,
    OnCreate? onCreate,
    OnUpgrade? onUpgrade,
  ) async {
    assert(collections.isNotEmpty);

    final crdtConfigTable = '${crdtTable}_config';

    if (sqliteCrdtIsWeb && !inMemory && path!.contains('/')) {
      path = path.substring(path.lastIndexOf('/') + 1);
    }
    assert(inMemory || path!.isNotEmpty);
    final databaseFactory = sqliteCrdtIsWeb
        ? databaseFactoryFfiWeb
        : databaseFactoryFfi;

    if (!sqliteCrdtIsWeb && sqliteCrdtIsLinux) {
      await databaseFactory.setDatabasesPath('.');
    }

    final db = await databaseFactory.openDatabase(
      inMemory ? inMemoryDatabasePath : path!,
      options: OpenDatabaseOptions(
        singleInstance: singleInstance,
        version: version,
        onCreate: (db, version) async {
          // Create crdt config table
          await db.execute('''
            CREATE TABLE $crdtConfigTable (
              key VARCHAR(255) NOT NULL,
              value VARCHAR(255),
              PRIMARY KEY (key)
            )
          ''');
          // Create CRDT metadata table
          await db.execute('''
            CREATE TABLE $crdtTable (
              collection VARCHAR(255) NOT NULL,
              id VARCHAR(255) NOT NULL,
              hlc VARCHAR(255) NOT NULL,
              node_id VARCHAR(255) GENERATED ALWAYS AS (SUBSTR(hlc, INSTR(hlc, 'Z-') + 7)) STORED,
              modified INTEGER NOT NULL,
              PRIMARY KEY (collection, id)
            )
          ''');
          // Create indexes for performance
          await (db.execute(
            'CREATE INDEX "node_id_idx" ON "crdt" ("node_id")',
          ));
          await (db.execute(
            'CREATE INDEX "modified_idx" ON "crdt" ("modified")',
          ));
          // Run custom onCreate operations
          await onCreate?.call(db, version);
        },
        onUpgrade: (db, from, to) async {
          await onUpgrade?.call(db, from, to);
          // TODO Sync all unknown values?
        },
      ),
    );

    final tableColumns = <String, Iterable<String>>{};
    for (final table in collections) {
      final crdtTableView = '${crdtTable}_${table}_view';

      // Read table information
      tableColumns[table] ??= (await db.rawQuery(
        'SELECT name FROM pragma_table_info(?1) WHERE pk > 0',
        [table],
      )).map((e) => e['name'] as String);
      final keys = tableColumns[table]!;

      // Create view over joined CRDT, and data tables
      await db.execute('''
        CREATE TEMP VIEW $crdtTableView AS
          SELECT
            $table.*,
            $crdtTable.id AS crdt_id,
            $crdtTable.hlc AS crdt_hlc,
            $crdtTable.node_id AS crdt_node_id,
            $crdtTable.modified AS crdt_modified,
            $table.${keys.first} IS NULL AS crdt_is_deleted
          FROM $crdtTable
          LEFT JOIN $table ON
            crdt_id = ${keys.map((e) => '$table.$e').join(" || '::' || ")}
          WHERE
            $crdtTable.collection = '$table'
      ''');
    }

    // Get canonical time
    final maxModified =
        (await db.rawQuery(
              'SELECT MAX(modified) AS modified FROM $crdtTable',
            )).first['modified']
            as int? ??
        0;

    // Get node id
    final result = await db.rawQuery(
      'SELECT value FROM $crdtConfigTable where key = ?1',
      ['node_id'],
    );
    final nodeId =
        (result.firstOrNull?['value'] as String?) ?? generateNodeId();
    // Store node id if it was generated
    if (result.isEmpty) {
      await db.rawQuery('INSERT INTO $crdtConfigTable VALUES (?1, ?2)', [
        'node_id',
        nodeId,
      ]);
    }

    return SqliteCrdt._(nodeId, maxModified, crdtTable, db, tableColumns);
  }

  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      query(sql, arguments);

  Future<Result> query(String sql, [List<Object?>? arguments]) async {
    final executor = CrdtExecutor(
      _db,
      crdtTable,
      _tableIndexes,
      canonicalHlc.increment(),
    );
    final result = await executor.query(sql, arguments);
    if (executor.affectedTables.isNotEmpty) {
      _canonicalTime = executor.hlc.logicalTime;
      _emitQueries(executor.affectedTables);
    }
    return result;
  }

  Future<void> transaction(
    Future<void> Function(CrdtExecutor txn) action,
  ) async {
    late final CrdtExecutor executor;
    await _db.transaction((t) async {
      executor = CrdtExecutor(
        t,
        crdtTable,
        _tableIndexes,
        canonicalHlc.increment(),
      );
      await action(executor);
    });
    if (executor.affectedTables.isNotEmpty) {
      _canonicalTime = executor.hlc.logicalTime;
      _emitQueries(executor.affectedTables);
    }
  }

  Future<void> close() => _db.close();

  @override
  Future<CrdtChangeset> getChangeset({
    String? onlyNodeId,
    String? exceptNodeId,
    int? modifiedOn,
    int? modifiedAfter,
    Iterable<String>? collections,
    Map<String, Query>? partialCollections,
  }) async {
    // Avoid invalid selector combinations
    assert(onlyNodeId == null || exceptNodeId == null);
    assert(modifiedOn == null || modifiedAfter == null);
    // Ensure no collection appears in both filters
    assert(
      collections == null ||
          partialCollections == null ||
          collections
              .toSet()
              .intersection(partialCollections.keys.toSet())
              .isEmpty,
    );

    // Return all collections if none have been specified
    if (partialCollections == null) collections ??= tables;
    // Coalesce collection filters
    final queries = {
      for (final t in collections ?? <String>{}) t: Query('SELECT * FROM $t'),
      ...partialCollections ?? {},
    };

    // Ensure all collections are known
    assert(
      queries.keys.toSet().difference(tables.toSet()).isEmpty,
      'Unrecognized table(s): ${queries.keys.toSet().difference(tables.toSet()).join(', ')}.',
    );

    final changeset = <String, Iterable<Map<String, dynamic>>>{};
    for (final entry in queries.entries) {
      final collection = entry.key;
      final query = entry.value;

      var i = (query.params?.length ?? 0) + 1;
      final whereStatements = [
        if (onlyNodeId != null) 'crdt_node_id = ?${i++}',
        if (exceptNodeId != null) 'crdt_node_id != ?${i++}',
        if (modifiedOn != null) 'crdt_modified = ?${i++}',
        if (modifiedAfter != null) 'crdt_modified > ?${i++}',
      ];
      final whereClause = whereStatements.isEmpty
          ? ''
          : 'WHERE ${whereStatements.join(' AND ')}';

      // Replace references to tables with their CRDT view counterparts
      var sql = SqlUtil.replaceTables(
        query.sql,
        (t) => '${crdtTable}_${t}_view',
      );
      print(sql);

      // Return all deleted records for partial collections.
      // This is necessary since it's impossible to know which deleted records
      // satisfy the filters on account of those fields no longer existing.
      //
      // For performance reasons we only do this if the modified filters  are
      // active, otherwise we risk generating a massive changeset with every
      // single record that has ever been deleted.
      //
      // In those cases the client should re-hydrate their local store using the
      // changeset as a canonical representation of their data subset.
      if ((modifiedOn != null || modifiedAfter != null) &&
          partialCollections != null &&
          partialCollections.containsKey(collection)) {
        // Get max modified date from join queries.
        // This ensures joined records appear when new relations are created
        // even if their modified date is older than the requested, e.g. getting
        // all products referenced in the purchases table.
        final isJoin = sql.toLowerCase().contains('join');
        if (isJoin) {
          final tables = SqlUtil.getAffectedTables(sql);
          assert(tables.length > 1);
          sql = sql.replaceFirst(
            RegExp(r'SELECT', caseSensitive: false),
            'SELECT MAX(${tables.map((t) => '$t.crdt_modified').join(', ')}) AS crdt_modified,',
          );
        }
        sql =
            '$sql UNION SELECT ${isJoin ? 'crdt_modified,' : ''} * FROM ${crdtTable}_${collection}_view WHERE crdt_is_deleted = true';
      }

      final result = await _db.rawQuery(
        'SELECT * FROM ($sql) $whereClause',
        [
          ...query.params ?? [],
          onlyNodeId,
          exceptNodeId,
          modifiedOn,
          modifiedAfter,
        ].nonNulls.toList(),
      );
      changeset[collection] = result.map(
        (e) => {
          'id': e['crdt_id'],
          'hlc': e['crdt_hlc'],
          'data': e['crdt_is_deleted'] == 1
              ? null
              : (Map.of(e)..removeWhere((k, _) => k.startsWith('crdt_'))),
        },
      );
    }

    return CrdtChangeset.fromMap(changeset);
  }

  @override
  Future<int> getLastModified({
    String? onlyNodeId,
    String? exceptNodeId,
  }) async {
    assert(onlyNodeId == null || exceptNodeId == null);
    final whereStatement = onlyNodeId != null
        ? r'WHERE node_id = $1'
        : exceptNodeId != null
        ? r'WHERE node_id != $1'
        : '';
    final result = await _db.rawQuery(
      'SELECT max(modified) AS modified FROM $crdtTable $whereStatement',
      [
        if (onlyNodeId != null) onlyNodeId,
        if (exceptNodeId != null) exceptNodeId,
      ],
    );
    return result.first['modified'] as int? ?? 0;
  }

  @override
  Future<void> merge(dynamic changeset) async {
    assert(changeset is Map<String, dynamic> || changeset is CrdtChangeset);
    if (changeset is! CrdtChangeset) {
      changeset = CrdtChangeset.fromMap(changeset);
    }
    // Quit early if there's nothing to do
    if (changeset.recordCount == 0) return;
    // Validate changeset and highest hlc therein
    final newCanonical = validateChangeset(changeset);

    // Iterate collections
    final affectedTables = <String>{};
    await _db.transaction((txn) async {
      for (final entry
          in changeset.entries
              as Iterable<MapEntry<String, Iterable<CrdtRecord>>>) {
        final table = entry.key;
        final records = entry.value;

        // Start by merging the CRDT records to filter out older HLCs
        final crdtBatch = txn.batch();
        for (final record in records) {
          crdtBatch.rawQuery(
            '''
              INSERT INTO $crdtTable (collection, id, hlc, modified)
                VALUES (?1, ?2, ?3, ?4)
              ON CONFLICT (collection, id) DO
                UPDATE SET
                  hlc = ?3,
                  modified = ?4
                WHERE excluded.hlc > $crdtTable.hlc
              RETURNING id
            ''',
            [table, record.id, '${record.hlc}', newCanonical],
          );
        }
        final crdtResult = (await crdtBatch.commit()).cast<List>();
        assert(crdtResult.length == records.length);

        // Get list of merged records
        var i = 0;
        final mergedRecords = records
            .where((_) => crdtResult[i++].isNotEmpty)
            .toList();

        // Merge records into data table
        final recordsBatch = txn.batch();
        for (final record in mergedRecords) {
          if (record.isDeleted) {
            var i = 1;
            final whereClause = _tableIndexes[table]!
                .map((e) => '$e = \$${i++}')
                .join(', ');
            recordsBatch.execute(
              'DELETE FROM $table WHERE $whereClause',
              record.id.split('::'),
            );
          } else {
            final data = record.data!;
            final updateStatement = data.keys
                .where((e) => !_tableIndexes[table]!.contains(e))
                .map((e) => '$e = \$${data.keys.toList().indexOf(e) + 1}')
                .join(',\n');
            recordsBatch.execute('''
              INSERT INTO $table (${data.keys.join(', ')})
                VALUES (${List.generate(data.length, (i) => '\$${i + 1}').join(', ')})
              ON CONFLICT (${_tableIndexes[table]!.join(', ')}) DO
                UPDATE SET $updateStatement
            ''', data.values.toList());
          }
        }
        if (mergedRecords.isNotEmpty) {
          await recordsBatch.commit();
          affectedTables.add(table);
        }
      }
    });

    _canonicalTime = newCanonical;
    _emitQueries(affectedTables);
  }

  Stream<Result> watch(String sql, [List<Object?>? params]) {
    late final StreamController<Result> controller;
    controller = StreamController<Result>(
      onListen: () {
        final query = Query(sql, params);
        _watches[controller] = query;
        _emitQuery(controller, query);
      },
      onCancel: () {
        _watches.remove(controller);
        controller.close();
      },
    );

    return controller.stream;
  }

  void _emitQueries(Set<String> affectedTables) {
    // Trigger watched queries for all affected tables
    final affectedWatches = _watches.entries.where(
      (e) => e.value.affectedTables.intersection(affectedTables).isNotEmpty,
    );
    for (final watch in affectedWatches) {
      unawaited(_emitQuery(watch.key, watch.value));
    }
  }

  Future<void> _emitQuery(
    StreamController<Result> controller,
    Query query,
  ) async {
    final result = await _db.rawQuery(query.sql, query.params);
    if (!controller.isClosed) {
      controller.add(result);
    } else {
      _watches.remove(controller);
    }
  }
}
