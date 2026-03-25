import 'dart:async';
import 'dart:convert';

import 'package:sqlite_crdt/sqlite_crdt.dart';
import 'package:test/test.dart';

Future<void> get ms => Future.delayed(Duration(milliseconds: 1));

void main() {
  late SqliteCrdt crdt;

  group('Basic', () {
    setUp(() async {
      crdt = await SqliteCrdt.openInMemory(
        collections: ['users', 'friends'],
        onCreate: (db, version) async {
          await db.execute('''
              CREATE TABLE users (
                id INTEGER NOT NULL,
                name TEXT,
                PRIMARY KEY (id)
              )
            ''');
          await db.execute('''
              CREATE TABLE friends (
                id1 INTEGER NOT NULL,
                id2 INTEGER NOT NULL,
                note TEXT,
                PRIMARY KEY (id1, id2)
              )
            ''');
        },
      );
    });

    test('Node ID', () {
      expect(crdt.nodeId.isEmpty, false);
    });

    test('Canonical time', () async {
      await insertUser(crdt, 1, 'John Doe');
      final can1 = crdt.canonicalTime;
      await Future.delayed(Duration(milliseconds: 1));
      await insertUser(crdt, 2, 'Jane Doe');
      final can2 = crdt.canonicalTime;

      final changeset = await crdt.getChangeset();
      final hlc1 = (changeset['users']!.first.hlc.logicalTime);
      final hlc2 = (changeset['users']!.last.hlc.logicalTime);

      expect(can2, greaterThan(can1));
      expect(hlc2, greaterThan(hlc1));
      expect(can1, hlc1);
      expect(can2, hlc2);
      expect(hlc2, crdt.canonicalTime);
    });

    test('Get last modified', () async {
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': Hlc.now('node1'),
            'data': {'id': 1, 'name': 'John Doe'},
          },
        ],
      });
      final hlc1 = crdt.canonicalTime;
      await crdt.merge({
        'friends': [
          {
            'id': '1::1',
            'hlc': Hlc.now('node2'),
            'data': {'id1': 1, 'id2': 2, 'note': 'BFFs'},
          },
        ],
      });
      final hlc2 = crdt.canonicalTime;
      expect(await crdt.getLastModified(), hlc2);
      expect(await crdt.getLastModified(onlyNodeId: 'node1'), hlc1);
      expect(await crdt.getLastModified(exceptNodeId: 'node2'), hlc1);
    });

    test('Insert', () async {
      await insertUser(crdt, 1, 'John Doe');
      final result = await crdt.query('SELECT * FROM users');
      expect(result.first['name'], 'John Doe');
    });

    test('Update', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc = crdt.canonicalTime;
      await updateUser(crdt, 1, 'Jane Doe');
      final result = await crdt.query('SELECT * FROM users');
      expect(result, [
        {'id': 1, 'name': 'Jane Doe'},
      ]);
      expect(crdt.canonicalTime, greaterThan(insertHlc));
    });

    test('Upsert', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc = crdt.canonicalTime;
      await crdt.execute(
        '''
          INSERT INTO users (id, name) VALUES (?1, ?2)
          ON CONFLICT (id) DO UPDATE SET name = ?2
        ''',
        [1, 'Jane Doe'],
      );
      final result = await crdt.query('SELECT * FROM users');
      expect(result, [
        {'id': 1, 'name': 'Jane Doe'},
      ]);
      expect(crdt.canonicalTime, greaterThan(insertHlc));
    });

    test('Replace', () async {
      await insertUser(crdt, 1, 'John Doe');
      final insertHlc = crdt.canonicalTime;
      await crdt.execute('REPLACE INTO users (id, name) VALUES (?1, ?2)', [
        1,
        'Jane Doe',
      ]);
      expect(await crdt.query('SELECT * FROM users'), [
        {'id': 1, 'name': 'Jane Doe'},
      ]);
      final changeset = await crdt.getChangeset();
      expect(changeset['users']!.first.hlc.logicalTime, greaterThan(insertHlc));
      expect(crdt.canonicalTime, greaterThan(insertHlc));
    });

    test('Delete', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.execute(
        '''
        DELETE FROM users
        WHERE id = ?1
      ''',
        [1],
      );
      final result = await crdt.query('SELECT * FROM users');
      expect(result, isEmpty);
      final changeset = await crdt.getChangeset();
      expect(changeset['users']!.first.isDeleted, isTrue);
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
  });

  group('Changesets', () {
    setUp(() async {
      crdt = await SqliteCrdt.openInMemory(
        collections: ['users', 'purchases', 'products', 'friends'],
        onCreate: (db, version) async {
          await db.execute('''
              CREATE TABLE users (
                id INTEGER NOT NULL,
                name TEXT,
                PRIMARY KEY (id)
              )
            ''');
          await db.execute('''
              CREATE TABLE purchases (
                id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                product_id INTEGER NOT NULL,
                price INTEGER NOT NULL,
                PRIMARY KEY (id)
              )
            ''');
          await db.execute('''
              CREATE TABLE products (
                id INTEGER NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (id)
              )
            ''');
          await db.execute('''
              CREATE TABLE friends (
                id1 INTEGER NOT NULL,
                id2 INTEGER NOT NULL,
                note TEXT,
                PRIMARY KEY (id1, id2)
              )
            ''');
        },
      );
    });

    test('Full changeset', () async {
      await insertUser(crdt, 1, 'John Doe');
      final changeset = await crdt.getChangeset();
      expect(
        (changeset['users']!.first.data as Map<String, Object?>)['name'],
        'John Doe',
      );
    });

    test('By node id', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      final changeset1 = await crdt.getChangeset(onlyNodeId: 'nodeId');
      expect(changeset1.recordCount, 1);
      expect(changeset1['users']!.first.data!['name'], 'Jane Doe');
      final changeset2 = await crdt.getChangeset(onlyNodeId: 'other_node_id');
      expect(changeset2.recordCount, 0);
    });

    test('Except node id', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      final changeset1 = await crdt.getChangeset(exceptNodeId: 'nodeId');
      expect(changeset1.recordCount, 1);
      expect(changeset1['users']!.first.data!['name'], 'John Doe');
      final changeset2 = await crdt.getChangeset(exceptNodeId: 'other_node_id');
      expect(changeset2.recordCount, 2);
    });

    test('Modified on', () async {
      await insertUser(crdt, 1, 'John Doe');
      final time = crdt.canonicalTime;
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      await ms;
      final changeset1 = await crdt.getChangeset(modifiedOn: time);
      expect(changeset1.recordCount, 1);
      expect(changeset1['users']!.first.data, {'id': 1, 'name': 'John Doe'});
      final changeset2 = await crdt.getChangeset(
        modifiedOn: crdt.canonicalTime,
      );
      expect(changeset2.recordCount, 1);
      expect(changeset2['users']!.first.data, {'id': 2, 'name': 'Jane Doe'});
    });

    test('Modified after', () async {
      await insertUser(crdt, 1, 'John Doe');
      final time = crdt.canonicalTime;
      await crdt.merge({
        'users': [
          {
            'id': '2',
            'hlc': Hlc.now('nodeId'),
            'data': {'id': 2, 'name': 'Jane Doe'},
          },
        ],
      });
      expect(crdt.canonicalTime > time, isTrue);
      await ms;
      final changeset = await crdt.getChangeset(modifiedAfter: time);
      expect(changeset.recordCount, 1);
      expect(changeset['users']!.first.data!['name'], 'Jane Doe');
    });

    test('Filter entire collections', () async {
      await insertUser(crdt, 1, 'John Doe');
      await insertUser(crdt, 2, 'Jane Doe');
      await insertPurchase(crdt, 10, 1, 100, 23);

      final changeset1 = await crdt.getChangeset(onlyCollections: ['users']);
      expect(changeset1.recordCount, 2);
      expect(changeset1['users'], isNotNull);
      expect(changeset1['friends'], isNull);

      final changeset2 = await crdt.getChangeset(
        onlyCollections: ['purchases'],
      );
      expect(changeset2.recordCount, 1);
      expect(changeset2['users'], isNull);
      expect(changeset2['purchases']!.first.data, {
        'id': 10,
        'user_id': 1,
        'product_id': 100,
        'price': 23,
      });
    });

    test('Filter specific fields', () async {
      await insertUser(crdt, 1, 'John Doe');
      await insertUser(crdt, 2, 'Jane Doe');
      await insertPurchase(crdt, 10, 1, 100, 23);
      await insertPurchase(crdt, 11, 1, 200, 24);

      final changeset1 = await crdt.getChangeset(
        partialCollections: {
          'users': Query('SELECT * FROM users WHERE users.id = ?1', [1]),
        },
      );
      expect(changeset1.recordCount, 1);
      expect(changeset1['users'], isNotNull);
      expect(changeset1['purchases'], isNull);

      final changeset2 = await crdt.getChangeset(
        partialCollections: {
          'purchases': Query(
            'SELECT * FROM purchases WHERE purchases.user_id = ?1',
            [1],
          ),
        },
      );
      expect(changeset2.recordCount, 2);
      expect(changeset2['users'], isNull);
      expect(changeset2['purchases'], isNotEmpty);
    });

    test('Filter on joined tables', () async {
      await insertUser(crdt, 1, 'John Doe');
      await insertUser(crdt, 2, 'Jane Doe');
      await insertPurchase(crdt, 10, 1, 100, 23);
      await insertPurchase(crdt, 11, 2, 200, 24);
      await insertPurchase(crdt, 12, 1, 300, 25);

      final changeset = await crdt.getChangeset(
        partialCollections: {
          'purchases': Query(
            '''
              SELECT purchases.* FROM purchases
              JOIN users ON users.id = purchases.user_id
              WHERE users.id = ?1
            ''',
            [1],
          ),
        },
      );
      expect(changeset.recordCount, 2);
      expect(changeset['users'], isNull);
      expect(changeset['purchases'], isNotNull);
      expect(changeset['purchases']!.first.data, {
        'id': 10,
        'user_id': 1,
        'product_id': 100,
        'price': 23,
      });
    });

    test('Get recent records from partial collections', () async {
      await insertProduct(crdt, 100, 'Water');
      final time = crdt.canonicalTime;
      await insertProduct(crdt, 101, 'Beer');
      expect(time < crdt.canonicalTime, isTrue);

      final changeset = await crdt.getChangeset(
        modifiedAfter: time,
        partialCollections: {
          'products': Query('SELECT * FROM products WHERE id >= ?1', [100]),
        },
      );
      expect(changeset.recordCount, 1);
      expect(changeset['products']!.first.data, {'id': 101, 'name': 'Beer'});
    });

    test('Delete from joined tables', () async {
      await insertUser(crdt, 1, 'John Doe');
      await insertUser(crdt, 2, 'Jane Doe');
      await insertPurchase(crdt, 10, 1, 100, 23);
      await insertPurchase(crdt, 11, 2, 200, 24);
      await insertPurchase(crdt, 12, 1, 300, 25);
      await crdt.execute('DELETE FROM purchases WHERE id = 10');

      final query = Query(
        '''
          SELECT purchases.* FROM purchases
          JOIN users ON users.id = purchases.user_id
          WHERE users.id = ?1
        ''',
        [1],
      );

      final changeset1 = await crdt.getChangeset(
        modifiedAfter: 0,
        partialCollections: {'purchases': query},
      );
      print(changeset1);
      expect(changeset1.recordCount, 2);
      expect(changeset1['users'], isNull);
      expect(changeset1['purchases'], isNotNull);
      expect(changeset1['purchases']!.last.isDeleted, isTrue);

      final changeset2 = await crdt.getChangeset(
        partialCollections: {'purchases': query},
      );
      expect(changeset2.recordCount, 1);
      expect(changeset2['users'], isNull);
      expect(changeset2['purchases'], isNotNull);
      expect(changeset2['purchases']!.first.isDeleted, isFalse);
    });

    // test('Get records older than the join relation', () async {
    //   await insertUser(crdt, 1, 'John Doe');
    //   await insertProduct(crdt, 100, 'Beer');
    //   final time = crdt.canonicalTime;
    //   await insertPurchase(crdt, 10, 1, 100, 23);
    //
    //   final changeset = await crdt.getChangeset(
    //     modifiedAfter: time,
    //     partialCollections: {
    //       'products': Query(
    //         '''
    //           SELECT products.* FROM products
    //           JOIN purchases ON products.id = purchases.product_id
    //           WHERE purchases.user_id = ?1
    //         ''',
    //         [1],
    //       ),
    //     },
    //   );
    //   expect(changeset.recordCount, 1);
    //   expect(changeset['users'], isNull);
    //   expect(changeset['products']!.first.data, {'id': 100, 'name': 'Beer'});
    // });

    test('Simple merge', () async {
      final hlc = Hlc.now('test_node_id');
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': hlc,
            'data': {'id': 1, 'name': 'John Doe'},
          },
        ],
      });
      final result = await crdt.query('SELECT * FROM users');
      expect(result, [
        {'id': 1, 'name': 'John Doe'},
      ]);
      final changeset = await crdt.getChangeset();
      expect(changeset['users']!.first.hlc, hlc);
      expect(crdt.canonicalTime >= hlc.logicalTime, isTrue);
    });

    test('Merge newer records', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': Hlc.now('test_node_id'),
            'data': {'id': 1, 'name': 'Jane Doe'},
          },
        ],
      });
      final result = await crdt.query('SELECT * FROM users');
      expect(result, [
        {'id': 1, 'name': 'Jane Doe'},
      ]);
    });

    test('Skip merging older records', () async {
      final hlc = Hlc.now('test_node_id');
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {
            'id': '1',
            'hlc': hlc,
            'data': {'id': 1, 'name': 'Jane Doe'},
          },
          {
            'id': '2',
            'hlc': hlc,
            'data': {'id': 2, 'name': 'Jenny Doe'},
          },
        ],
      });
      final result = await crdt.query('SELECT * FROM users');
      expect(result, [
        {'id': 1, 'name': 'John Doe'},
        {'id': 2, 'name': 'Jenny Doe'},
      ]);
    });

    test('Merge deleted records', () async {
      await insertUser(crdt, 1, 'John Doe');
      await crdt.merge({
        'users': [
          {'id': '1', 'hlc': Hlc.now('test_node_id'), 'data': null},
        ],
      });
      final result = await crdt.query('SELECT * FROM users');
      expect(result, isEmpty);
    });

    test('Merge changeset with multiple tables', () async {
      final hlc = Hlc.now('test_node_id');
      final changeset = {
        'users': [
          {
            'id': '1',
            'hlc': hlc,
            'data': {'id': 1, 'name': 'John Doe'},
          },
        ],
        'friends': [
          {
            'id': '1::2',
            'hlc': hlc,
            'data': {'id1': 1, 'id2': 2, 'note': 'BFFs'},
          },
        ],
      };
      await crdt.merge(changeset);

      expect(await crdt.query('SELECT * FROM users'), [
        {'id': 1, 'name': 'John Doe'},
      ]);
      expect(await crdt.query('SELECT * FROM friends'), [
        {'id1': 1, 'id2': 2, 'note': 'BFFs'},
      ]);
      expect(jsonEncode(await crdt.getChangeset()), jsonEncode(changeset));
    });

    test('Merge large changeset', () async {
      final length = 10000;
      final hlc = Hlc.now('test_node_id');
      final changeset = {
        'users': List.generate(
          length,
          (i) => {
            'id': '$i',
            'hlc': hlc,
            'data': {'id': i, 'name': 'John Doe $i'},
          },
        ),
      };
      await crdt.merge(changeset);

      final result = await crdt.query('SELECT * FROM users');
      expect(result.length, length);
      expect(result.first, {'id': 0, 'name': 'John Doe 0'});
      expect(result.last, {'id': length - 1, 'name': 'John Doe ${length - 1}'});
    });
  });

  group('Write from query', () {
    setUp(() async {
      crdt = await SqliteCrdt.openInMemory(
        collections: ['users', 'other_users'],
        onCreate: (db, version) async {
          await db.execute('''
              CREATE TABLE users (
                id INTEGER NOT NULL,
                name TEXT,
                PRIMARY KEY (id)
              )
            ''');
          await db.execute('''
              CREATE TABLE other_users (
                  id INTEGER NOT NULL,
                  name TEXT,
                  PRIMARY KEY (id)
                )
              ''');
        },
      );
      await insertUser(crdt, 1, 'John Doe');
    });

    test('Insert from select', () async {
      await crdt.execute('''
        INSERT INTO other_users (id, name)
        SELECT id, name FROM users
      ''');
      final result1 = await crdt.query('SELECT * FROM users');
      final result2 = await crdt.query('SELECT * FROM other_users');
      expect(result1[0], result2[0]);
      final changeset = await crdt.getChangeset();
      expect(
        changeset['users']!.first.hlc,
        isNot(changeset['other_users']!.first.hlc),
      );
    });
  });

  group('Watch', () {
    setUp(() async {
      crdt = await SqliteCrdt.openInMemory(
        collections: ['users', 'purchases'],
        onCreate: (db, version) async {
          await db.execute('''
              CREATE TABLE users (
                id INTEGER NOT NULL,
                name TEXT,
                PRIMARY KEY (id)
              )
            ''');
          await db.execute('''
              CREATE TABLE purchases (
                id INTEGER NOT NULL,
                user_id INTEGER NOT NULL,
                product_id INTEGER NOT NULL,
                price INTEGER NOT NULL,
                PRIMARY KEY (id)
              )
            ''');
        },
      );
    });

    test('Emit on watch', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [
            {'id': 1, 'name': 'John Doe'},
          ],
        ]),
      );
      await streamTest;
    });

    test('Emit on insert', () async {
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [],
          [
            {'id': 1, 'name': 'John Doe'},
          ],
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
          [
            {'id': 1, 'name': 'John Doe'},
          ],
          [
            {'id': 1, 'name': 'Jane Doe'},
          ],
        ]),
      );
      await updateUser(crdt, 1, 'Jane Doe');
      await streamTest;
    });

    test('Emit on delete', () async {
      await insertUser(crdt, 1, 'John Doe');
      final streamTest = expectLater(
        crdt.watch('SELECT * FROM users'),
        emitsInOrder([
          [
            {'id': 1, 'name': 'John Doe'},
          ],
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
          [
            {'id': 1, 'name': 'John Doe'},
            {'id': 2, 'name': 'Jane Doe'},
          ],
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
            'id': '1',
            'hlc': Hlc.now('test_node_id'),
            'data': {'id': 1, 'name': 'John Doe'},
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
          [
            {'id': 1, 'name': 'John Doe'},
          ],
        ]),
      );
      await insertPurchase(crdt, 1, 1, 12, 23);
      await insertUser(crdt, 1, 'John Doe');
      await streamTest;
    });

    test('Emit on all selected tables', () async {
      final streamTest = expectLater(
        crdt.watch(
          'SELECT users.name, price FROM users LEFT JOIN purchases ON users.id = user_id',
        ),
        emitsInOrder([
          [],
          (List<Map<String, Object?>> e) =>
              e.first['name'] == 'John Doe' && e.first['price'] == null,
          (List<Map<String, Object?>> e) =>
              e.first['name'] == 'John Doe' && e.first['price'] == 23,
        ]),
      );
      await insertUser(crdt, 1, 'John Doe');
      await insertPurchase(crdt, 1, 1, 12, 23);
      await streamTest;
    });
  });
}

Future<void> insertUser(dynamic crdt, int id, String name) async {
  await Future.delayed(Duration(milliseconds: 1));
  await crdt.execute(
    '''
    INSERT INTO users (id, name)
    VALUES (?1, ?2)
  ''',
    [id, name],
  );
}

Future<void> updateUser(SqliteCrdt crdt, int id, String name) => crdt.execute(
  '''
    UPDATE users SET name = ?2
    WHERE id = ?1
  ''',
  [id, name],
);

Future<void> deleteUser(SqliteCrdt crdt, int id) =>
    crdt.execute('DELETE FROM users WHERE id = ?1', [id]);

Future<void> insertPurchase(
  SqliteCrdt crdt,
  int id,
  int userId,
  int productId,
  int price,
) async {
  await Future.delayed(Duration(milliseconds: 1));
  await crdt.execute(
    '''
      INSERT INTO purchases (id, user_id, product_id, price)
      VALUES (?1, ?2, ?3, ?4)
    ''',
    [id, userId, productId, price],
  );
}

Future<void> insertProduct(SqliteCrdt crdt, int id, String name) async {
  await Future.delayed(Duration(milliseconds: 1));
  await crdt.execute(
    '''
      INSERT INTO products (id, name)
      VALUES (?1, ?2)
    ''',
    [id, name],
  );
}
