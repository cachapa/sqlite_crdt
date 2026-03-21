import 'package:sqlite_crdt/src/sql_util.dart';
import 'package:sqlparser/sqlparser.dart';

import '../sqlite_crdt.dart';

final _sqlEngine = SqlEngine();

class CrdtExecutor {
  final DatabaseExecutor _db;
  final String crdtTable;
  final Map<String, Iterable<String>> _crdtFields;
  final Hlc hlc;

  final affectedTables = <String>{};

  CrdtExecutor(this._db, this.crdtTable, this._crdtFields, this.hlc);

  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      query(sql, arguments);

  Future<Result> query(String sql, [List<Object?>? arguments]) {
    final statement = _sqlEngine
        .parse(ParserEntrypoint.statement, sql)
        .rootNode;

    return switch (statement) {
      InsertStatement _ ||
      UpdateStatement _ ||
      DeleteStatement _ => _execute(statement as HasPrimarySource, arguments),
      _ => _db.rawQuery(sql, arguments),
    };
  }

  Future<Result> _execute(
    HasPrimarySource statement,
    List<Object?>? args,
  ) async {
    // This package uses its own Returning statement to get changed rows.
    assert(
      statement.childNodes.whereType<Returning>().isEmpty,
      'The RETURNING clause is not supported by sqlite_crdt.',
    );

    final table = (statement.table as TableReference).tableName;
    assert(
      _crdtFields.keys.contains(table),
      'Unknown table "$table". Please make sure to specify all CRDT tables in the constructor.',
    );
    final indexes = _crdtFields[table]!;

    final alteredSql = '${statement.span!.text} RETURNING *';
    final result = await _db.rawQuery(alteredSql, args);

    if (result.isNotEmpty) {
      // Remember affected table
      affectedTables.add(table);
      // Insert CRDT records
      // final sourceColumns = indexes.join(', ');
      for (final row in result) {
        await _db.execute(
          '''
            INSERT INTO $crdtTable (collection, id, hlc, modified)
              VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT (collection, id) DO
              UPDATE SET
                hlc = ?3,
                modified = ?4
            WHERE excluded.hlc > $crdtTable.hlc
          ''',
          [
            table,
            row.entries
                .where((e) => indexes.contains(e.key))
                .map((e) => e.value)
                .join('::'),
            hlc.toString(),
            hlc.logicalTime,
          ],
        );
      }
    }

    return result;
  }
}

class Query {
  final String sql;
  final List<Object?>? params;
  late final Set<String> affectedTables = SqlUtil.getAffectedTables(sql);

  Query(this.sql, [this.params]) {
    assert(
      _sqlEngine.parse(ParserEntrypoint.statement, sql).rootNode
          is SelectStatement,
    );
  }
}
