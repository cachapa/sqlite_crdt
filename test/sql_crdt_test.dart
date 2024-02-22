import 'dart:async';

import 'package:sql_crdt/sql_crdt.dart';
import 'package:test/test.dart';

void main() {}

void runSqlCrdtTests(SqlCrdt crdt) {
  group('Basic', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() => dropAllTables(crdt));

    test('Node ID', () {
      expect(crdt.nodeId.isEmpty, false);
    });

    test('Canonical time', () async {
      await insertUser(crdt, 1, 'John Doe');
      final result = await crdt.query('SELECT * FROM users');
      final hlc = (result.first['hlc'] as String).toHlc;
      expect(crdt.canonicalTime, hlc);

      await insertUser(crdt, 2, 'Jane Doe');
      final newResult = await crdt.query('SELECT * FROM users');
      final newHlc = (newResult.last['hlc'] as String).toHlc;
      expect(newHlc > hlc, isTrue);
      expect(crdt.canonicalTime, newHlc);
    });

    test('Create table', () async {
      await crdt.execute('''
        CREATE TABLE test (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
      expect(await crdt.query('SELECT * FROM test'), []);
      expect((await crdt.getTables()).toList(), ['users', 'test']);
    });

    test('Insert', () async {
      await insertUser(crdt, 1, 'John Doe');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'John Doe');
    });

    test('Insert without arguments', () async {
      await crdt.execute('''
        INSERT INTO users (id, name)
        VALUES (1, 'John Doe')
      ''');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'John Doe');
    });

    test('Update', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc =
          (await crdt.query('SELECT hlc FROM users')).first['hlc'] as String;
      await updateUser(crdt, 1, 'Jane Doe');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'Jane Doe');
      expect((result.first['hlc'] as String).compareTo(insertHlc), 1);
    });

    test('Update without arguments', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc =
          (await crdt.query('SELECT hlc FROM users')).first['hlc'] as String;
      await crdt.execute('''
        UPDATE users SET name = 'Jane Doe'
        WHERE id = 1
      ''');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'Jane Doe');
      expect((result.first['hlc'] as String).compareTo(insertHlc), 1);
    });

    test('Upsert', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc =
          (await crdt.query('SELECT hlc FROM users')).first['hlc'] as String;
      await crdt.execute('''
        INSERT INTO users (id, name) VALUES (?1, ?2)
        ON CONFLICT (id) DO UPDATE SET name = ?2
      ''', [1, 'Jane Doe']);
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'Jane Doe');
      expect((result.first['hlc'] as String).compareTo(insertHlc), 1);
    });

    test('Upsert without arguments', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc =
          (await crdt.query('SELECT hlc FROM users')).first['hlc'] as String;
      await crdt.execute('''
        INSERT INTO users (id, name) VALUES (1, 'Jane Doe')
        ON CONFLICT (id) DO UPDATE SET name = 'Jane Doe'
      ''');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'Jane Doe');
      expect((result.first['hlc'] as String).compareTo(insertHlc), 1);
    });

    test('Delete', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.execute('''
        DELETE FROM users
        WHERE id = ?1
      ''', [1]);
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'John Doe');
      expect(result.first['is_deleted'], 1);
    });

    test('Delete without arguments', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.execute('''
        DELETE FROM users
        WHERE id = 1
      ''');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'John Doe');
      expect(result.first['is_deleted'], 1);
    });

    test('Transaction', () async {
      await crdt.transaction((txn) async {
        await insertUser(txn, 1, 'John Doe');
        await insertUser(txn, 2, 'Jane Doe');
      });
      final result = await crdt.query('SELECT * FROM users');
      expect(result.length, 2);
      expect(result.first['hlc'], result.last['hlc']);
    });

    test('Changeset', () async {
      await insertUser(crdt, 1, 'John Doe');
      final result = await crdt.getChangeset();
      expect(result['users']!.first['name'], 'John Doe');
    });

    test('Simple merge', () async {
      final hlc = Hlc.now('test_node_id');
      await crdt.merge({
        'users': [
          {
            'id': 1,
            'name': 'John Doe',
            'hlc': hlc,
          },
        ],
      });
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'John Doe');
      expect(result.first['hlc'] as String, hlc.toString());
    });

    test('Merge large changeset', () async {
      final length = 10000;
      final hlc = Hlc.now('test_node_id');
      final changeset = {
        'users': List.generate(
          length,
          (i) => {
            'id': i,
            'name': 'John Doe $i',
            'hlc': hlc,
          },
        ),
      };
      await crdt.merge(changeset);

      final result = await crdt.query('SELECT * FROM users');
      expect(result.length, length);
      expect(result.first['name'], 'John Doe 0');
      expect(result.first['hlc'] as String, hlc.toString());
      expect(result.last['name'], 'John Doe ${length - 1}');
      expect(result.first['hlc'] as String, hlc.toString());
    });
  });

  group('Write from query', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
      await crdt.execute('''
        CREATE TABLE other_users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
      await insertUser(crdt, 1, 'John Doe');
    });

    tearDown(() => dropAllTables(crdt));

    test('Insert from select', () async {
      await crdt.execute('''
        INSERT INTO other_users (id, name)
        SELECT id, name FROM users
      ''');
      final result1 = await crdt.query('SELECT * FROM users');
      final result2 = await crdt.query('SELECT * FROM other_users');
      expect(result2.first['name'], 'John Doe');
      expect(result2.first['hlc'], isNot(result1.first['hlc']));
    });
  });

  group('Watch', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
      await crdt.execute('''
        CREATE TABLE purchases (
          id INTEGER NOT NULL,
          user_id INTEGER NOT NULL,
          price INTEGER NOT NULL,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() => dropAllTables(crdt));

    test('Emit on watch', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emits((List<Map<String, Object?>> e) => e.first['name'] == 'John Doe'),
      );
      await streamTest;
    });

    test('Emit on insert', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) => e.first['name'] == 'John Doe',
        ]),
      );
      await insertUser(crdt, 1, 'John Doe');
      await streamTest;
    });

    test('Emit on update', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          (List<Map<String, Object?>> e) => e.first['name'] == 'John Doe',
          (List<Map<String, Object?>> e) => e.first['name'] == 'Jane Doe',
        ]),
      );
      await updateUser(crdt, 1, 'Jane Doe');
      await streamTest;
    });

    test('Emit on delete', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users WHERE is_deleted = 0'),
        emitsInOrder([
          (List<Map<String, Object?>> e) => e.first['name'] == 'John Doe',
          [],
        ]),
      );
      await deleteUser(crdt, 1);
      await streamTest;
    });

    test('Emit on transaction', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) =>
              e.first['name'] == 'John Doe' && e.last['name'] == 'Jane Doe',
        ]),
      );
      await crdt.transaction((txn) async {
        await insertUser(txn, 1, 'John Doe');
        await insertUser(txn, 2, 'Jane Doe');
      });
      await streamTest;
    });

    test('Emit on merge', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) => e.first['name'] == 'John Doe',
        ]),
      );
      await crdt.merge({
        'users': [
          {
            'id': 1,
            'name': 'John Doe',
            'hlc': Hlc.now('test_node_id'),
          },
        ],
      });
      await streamTest;
    });

    test('Emit only on selected table', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) => e.first['name'] == 'John Doe',
        ]),
      );
      await insertPurchase(crdt, 1, 1, 12);
      await insertUser(crdt, 1, 'John Doe');
      await streamTest;
    });

    test('Emit on all selected tables', () async {
      final streamTest = expectLater(
        crdt.watch(
            'SELECT users.name, price FROM users LEFT JOIN purchases ON users.id = user_id'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) =>
              e.first['name'] == 'John Doe' && e.first['price'] == null,
          (List<Map<String, Object?>> e) =>
              e.first['name'] == 'John Doe' && e.first['price'] == 12,
        ]),
      );
      await insertUser(crdt, 1, 'John Doe');
      await insertPurchase(crdt, 1, 1, 12);
      await streamTest;
    });
  });
}

FutureOr<void> insertUser(dynamic crdt, int id, String name) => crdt.execute('''
      INSERT INTO users (id, name)
      VALUES (?1, ?2)
    ''', [id, name]);

Future<void> updateUser(SqlCrdt crdt, int id, String name) => crdt.execute('''
      UPDATE users SET name = ?2
      WHERE id = ?1
    ''', [id, name]);

Future<void> deleteUser(SqlCrdt crdt, int id) =>
    crdt.execute('DELETE FROM users WHERE id = ?1', [id]);

Future<void> insertPurchase(SqlCrdt crdt, int id, int userId, int price) =>
    crdt.execute('''
      INSERT INTO purchases (id, user_id, price)
      VALUES (?1, ?2, ?3)
    ''', [id, userId, price]);

Future<void> dropAllTables(SqlCrdt crdt) async =>
    Future.wait((await crdt.getTables())
        .map((table) => 'DROP TABLE $table')
        .map((sql) => crdt.execute(sql)));
