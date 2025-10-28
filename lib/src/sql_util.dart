import 'package:sqlparser/sqlparser.dart';

class SqlUtil {
  static final _sqlEngine = SqlEngine();

  SqlUtil._();

  /// Identifies all affected tables in a given SQL statement.
  static Set<String> getAffectedTables(String sql) {
    try {
      return _recAffectedTables(
        _sqlEngine.parse(ParserEntrypoint.statement, sql).rootNode
            as BaseSelectStatement,
      );
    } catch (_) {
      print('Error parsing statement: $sql');
      rethrow;
    }
  }

  static Set<String> _recAffectedTables(AstNode node) {
    if (node is TableReference) return {node.tableName};
    return node.allDescendants.fold(
      {},
      (prev, e) => prev..addAll(_recAffectedTables(e)),
    );
  }

  /// Allows replacing all table references to tables in a given SQL statement.
  static String replaceTables(
    String sql,
    String Function(String table) replace,
  ) {
    // Get all table references, including column disambiguation
    final references =
        _sqlEngine
            .parse(ParserEntrypoint.statement, sql)
            .rootNode
            .allDescendants
            .where(
              (e) =>
                  e is TableReference ||
                  (e is StarResultColumn && e.tableName != null) ||
                  (e is Reference && e.entityName != null),
            )
            .toList()
          // Sort the references by their string position in reverse
          ..sort((a, b) => b.firstPosition.compareTo(a.firstPosition));

    // Replace table names in reverse to maintain the original positions
    for (final reference in references) {
      final table = switch (reference) {
        TableReference() => reference.tableName,
        StarResultColumn() => reference.tableName!,
        Reference() => reference.entityName!,
        _ => throw ('Unknown type: ${reference.runtimeType}'),
      };

      //     reference is TableReference
      //           ? reference.tableName
      //           : (reference as Reference).entityName!;

      sql = sql.replaceFirst(table, replace(table), reference.firstPosition);
    }

    return sql;
  }

  /// Returns all top-level columns in a where statement containing variables.
  static Set<String> getWhereVariableColumns(String sql) {
    try {
      final where =
          (_sqlEngine.parse(ParserEntrypoint.statement, sql).rootNode
                  as SelectStatement)
              .where;
      return where != null ? _recWhereVariableColumns(where) : {};
    } catch (_) {
      print('Error parsing statement: $sql');
      rethrow;
    }
  }

  static Set<String> _recWhereVariableColumns(Expression expr) =>
      switch (expr) {
        Parentheses _ => _recWhereVariableColumns(expr.expression),
        BinaryExpression() =>
          expr.left is NumberedVariable
              ? {'${expr.right}'}
              : expr.right is NumberedVariable
              ? {'${expr.left}'}
              : {
                  ..._recWhereVariableColumns(expr.left),
                  ..._recWhereVariableColumns(expr.right),
                },
        _ => {},
      };
}
