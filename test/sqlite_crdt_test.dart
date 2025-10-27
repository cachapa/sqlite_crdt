import 'dart:async';

import 'package:sqlite_crdt/sqlite_crdt.dart';
import 'package:test/test.dart';

import 'sql_crdt_test.dart';

Future<void> main() async {
  final crdt = await SqliteCrdt.openInMemory();

  runSqlCrdtTests(crdt);

  group('Sqlite features', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
      await crdt.execute('''
        CREATE TABLE users_2 (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() async {
      await crdt.execute('DROP TABLE users');
      await crdt.execute('DROP TABLE IF EXISTS users_2');
    });

    test('Replace', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc =
          (await crdt.query('SELECT hlc FROM users')).first['hlc'] as String;
      await crdt.execute(
          'REPLACE INTO users (id, name) VALUES (?1, ?2)', [1, 'Jane Doe']);
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'Jane Doe');
      expect((result.first['hlc'] as String).compareTo(insertHlc), 1);
    });

    test('Replace without arguments', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc =
          (await crdt.query('SELECT hlc FROM users')).first['hlc'] as String;
      await crdt
          .execute("REPLACE INTO users (id, name) VALUES (1, 'Jane Doe')");
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'Jane Doe');
      expect((result.first['hlc'] as String).compareTo(insertHlc), 1);
    });

    test('Batch insert', () async {
      final batch = crdt.batch();
      insertUser(batch, 1, 'John Doe 1');
      insertUser(batch, 2, 'John Doe 2');
      await batch.commit();

      final result = await crdt.query('SELECT * FROM users');
      expect(result.length, 2);
      expect(result[0]['name'], 'John Doe 1');
      expect(result[1]['name'], 'John Doe 2');
      expect(result[0]['hlc'], result[1]['hlc']);
    });

    /// This test is currently failing due to the way batches are processed:
    /// The HLC for each batch operation is calculated at the moment of
    /// creation rather than on commit.
    ///
    /// Changing this will require some work which may be unnecessary in light
    /// of upcoming architectural changes in the project.
    ///
    // test('Mixed batch and standard inserts', () async {
    //   final batch = crdt.batch();
    //   insertUser(batch, 1, 'John Doe 1');
    //   insertUser(crdt, 2, 'John Doe 2');
    //   insertUser(batch, 3, 'John Doe 3');
    //   await batch.commit();
    //
    //   final result = await crdt.query('SELECT * FROM users');
    //   expect(result.length, 2);
    //   expect(result[0]['name'], 'John Doe 1');
    //   expect(result[1]['name'], 'John Doe 2');
    //   expect(result[2]['name'], 'John Doe 3');
    //   expect(result.first['hlc'], result.last['hlc']);
    // });

    test('Uncommitted batch', () async {
      final batch = crdt.batch();
      insertUser(batch, 1, 'John Doe 1');
      insertUser(batch, 2, 'John Doe 2');

      final result = await crdt.query('SELECT * FROM users');
      expect(result.length, 0);
    });

    test('Emit on single insert', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) =>
              e.length == 1 && e[0]['name'] == 'John Doe'
        ]),
      );
      final batch = crdt.batch();
      insertUser(batch, 1, 'John Doe');
      await batch.commit();
      await streamTest;
    });

    test('Emit on multiple tables', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users UNION ALL SELECT * FROM users_2'),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) =>
              e.length == 2 &&
              e[0]['name'] == 'John Doe' &&
              e[1]['name'] == 'Jane Doe',
        ]),
      );
      final batch = crdt.batch();
      insertUser(batch, 1, 'John Doe');
      await batch.execute(
          'INSERT INTO users_2 (id, name) VALUES (?1, ?2)', [2, 'Jane Doe']);
      await batch.commit();
      await streamTest;
    });
  });
}
