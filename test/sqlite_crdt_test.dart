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
    });

    tearDown(() async {
      await crdt.execute('DROP TABLE users');
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
      expect(result.first['name'], 'John Doe 1');
      expect(result.last['name'], 'John Doe 2');
      expect(result.first['hlc'], result.last['hlc']);
    });

    test('Uncommitted batch', () async {
      final batch = crdt.batch();
      insertUser(batch, 1, 'John Doe 1');
      insertUser(batch, 2, 'John Doe 2');

      final result = await crdt.query('SELECT * FROM users');
      expect(result.length, 0);
    });
  });
}
