import 'package:sqlite_crdt/src/sql_util.dart';
import 'package:test/test.dart';

Set<String> getAffectedTables(String sql) => SqlUtil.getAffectedTables(sql);

void main() {
  group('Affected tables', () {
    test('Simple query', () {
      expect(getAffectedTables('SELECT * FROM users'), {'users'});
    });

    test('Join', () {
      expect(
        getAffectedTables('''
        SELECT * FROM users
        JOIN purchases ON users.id = purchases.user_id
      '''),
        {'users', 'purchases'},
      );
    });

    test('Union', () {
      expect(
        getAffectedTables('''
        SELECT * FROM naughty
        UNION ALL
        SELECT * FROM nice
      '''),
        {'naughty', 'nice'},
      );
    });

    test('Intersect', () {
      expect(
        getAffectedTables('''
        SELECT * FROM naughty
        INTERSECT
        SELECT * FROM nice
      '''),
        {'naughty', 'nice'},
      );
    });

    test('Subselect', () {
      expect(
        getAffectedTables('''
        SELECT * FROM (SELECT * FROM users)
      '''),
        {'users'},
      );
    });

    test('All together!', () {
      expect(
        getAffectedTables('''
        SELECT * FROM table1
        JOIN table2 ON id1 = id2
        UNION
        SELECT * FROM (
          SELECT * FROM table3 JOIN table4 ON id3 = id4
          INTERSECT
          SELECT * FROM (SELECT * FROM table5)
        )
        INTERSECT
        SELECT * FROM table6
      '''),
        {'table1', 'table2', 'table3', 'table4', 'table5', 'table6'},
      );
    });
  });

  // group('Add changeset clauses', () {
  //   test('Simple query', () {
  //     final sql = SqlUtil.addChangesetClauses(
  //       'test',
  //       'SELECT * FROM test',
  //       exceptNodeId: 'node_id',
  //       modifiedAfter: Hlc.zero('node_id'),
  //     );
  //     expect(
  //       sql,
  //       "SELECT * FROM test WHERE node_id != 'node_id' AND modified > '1970-01-01T00:00:00.000Z-0000-node_id'",
  //     );
  //   });
  //
  //   test('Simple query with where clause', () {
  //     final sql = SqlUtil.addChangesetClauses(
  //       'test',
  //       'SELECT * FROM test WHERE a != ?1 and b = ?2',
  //       exceptNodeId: 'node_id',
  //       modifiedAfter: Hlc.zero('node_id'),
  //     );
  //     expect(
  //       sql,
  //       "SELECT * FROM test WHERE node_id != 'node_id' AND modified > '1970-01-01T00:00:00.000Z-0000-node_id' AND a != ?1 AND b = ?2",
  //     );
  //   });
  // });

  // group('Transform automatic to explicit parameters', () {
  //   test('Simple automatic parameters', () {
  //     final sql = 'SELECT * FROM users WHERE name = ? AND age = ?';
  //     final transformed = SqlUtil.transformAutomaticExplicitSql(sql);
  //     expect(transformed, 'SELECT * FROM users WHERE name = ?1 AND age = ?2');
  //   });
  //
  //   test('Already explicit parameters', () {
  //     final sql = 'SELECT * FROM users WHERE name = ?1 AND age = ?2';
  //     final transformed = SqlUtil.transformAutomaticExplicitSql(sql);
  //     expect(transformed, 'SELECT * FROM users WHERE name = ?1 AND age = ?2');
  //   });
  //
  //   test('Mixed automatic and explicit parameters', () {
  //     final sql =
  //         'SELECT * FROM users WHERE name = ? AND age = ?2 AND city = ?';
  //     final transformed = SqlUtil.transformAutomaticExplicitSql(sql);
  //     expect(
  //       transformed,
  //       'SELECT * FROM users WHERE name = ?1 AND age = ?2 AND city = ?3',
  //     );
  //   });
  //
  //   test('Multiple automatic parameters in complex query', () {
  //     final sql = '''SELECT * FROM users
  //       JOIN orders ON users.id = orders.user_id
  //       WHERE users.name = ? AND orders.status = ? AND orders.total > ?
  //     ''';
  //     final transformed = SqlUtil.transformAutomaticExplicitSql(sql);
  //     expect(
  //       transformed,
  //       'SELECT * FROM users JOIN orders ON users.id = orders.user_id WHERE users.name = ?1 AND orders.status = ?2 AND orders.total > ?3',
  //     );
  //   });
  //
  //   test('Automatic parameters in INSERT statement', () {
  //     final sql = 'INSERT INTO users (name, age, city) VALUES (?, ?, ?)';
  //     final transformed = SqlUtil.transformAutomaticExplicitSql(sql);
  //     expect(
  //       transformed,
  //       'INSERT INTO users (name, age, city) VALUES (?1, ?2, ?3)',
  //     );
  //   });
  //
  //   test('Automatic parameters in UPDATE statement', () {
  //     final sql = 'UPDATE users SET name = ?, age = ? WHERE id = ?';
  //     final transformed = SqlUtil.transformAutomaticExplicitSql(sql);
  //     expect(transformed, 'UPDATE users SET name = ?1, age = ?2 WHERE id = ?3');
  //   });
  // });
}
