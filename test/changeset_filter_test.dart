import 'package:sqlite_crdt/src/sql_util.dart';
import 'package:test/test.dart';

void main() {
  group('Affected tables', () {
    test('Simple query', () {
      final sql =
          'SELECT test_table.* FROM test_table JOIN (SELECT * FROM some_other_table WHERE some_other_table.id = ?1) ON test_table.other_table = other_table.test_table';
      print(SqlUtil.replaceTables(sql, (table) => '---$table---'));
      throw ('TEST');
    });
  });
}
