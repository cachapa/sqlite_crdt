import 'package:sqlite_crdt/sqlite_crdt.dart';

Future<void> main() async {
  // Create or load the database
  final crdt = await SqliteCrdt.openInMemory(
    collections: ['users'],
    onCreate: (db, version) async {
      // Create a table
      await db.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
    },
  );

  print('Watch the users table');
  crdt
      .watch('SELECT * FROM users')
      .listen((e) => print('${e.isEmpty ? '[]' : e.join('\n')}\n'));
  // Watches emit immediately, so allow a time for the initial query to run:
  await Future.delayed(Duration(milliseconds: 10));

  print('Insert a user');
  await crdt.execute(
    '''
      INSERT INTO users (id, name)
      VALUES (?1, ?2)
    ''',
    [1, 'John Doe'],
  );
  await Future.delayed(Duration(milliseconds: 10));

  print('Query the database');
  final result = await crdt.query('SELECT * FROM users');
  print(result.first['name']);

  print('Delete the user');
  await crdt.execute('DELETE FROM users WHERE id = ?1', [1]);
  await Future.delayed(Duration(milliseconds: 10));

  print('Merge a remote dataset');
  await crdt.merge({
    'users': [
      {
        'id': '2',
        'hlc': Hlc.now(generateNodeId()),
        'data': {'id': 2, 'name': 'Jane Doe'},
      },
    ],
  });
  await Future.delayed(Duration(milliseconds: 10));

  print('Update a user');
  await crdt.execute(
    '''
      UPDATE users SET name = ?1
      WHERE id = ?2
    ''',
    ['Jane Doe', 2],
  );
  await Future.delayed(Duration(milliseconds: 10));

  print('Multiple writes inside a transaction for atomic updates');
  await crdt.transaction((txn) async {
    // Make sure you use the transaction object (txn)
    // Using [crdt] here will cause a deadlock
    await txn.execute(
      '''
        INSERT INTO users (id, name)
        VALUES (?1, ?2)
      ''',
      [3, 'Uncle Doe'],
    );
    await txn.execute(
      '''
        INSERT INTO users (id, name)
        VALUES (?1, ?2)
      ''',
      [4, 'Grandma Doe'],
    );
  });
  await Future.delayed(Duration(milliseconds: 10));

  print('Create a changeset to sync with other nodes');
  final changeset = await crdt.getChangeset();
  print('Changeset size: ${changeset.recordCount} records');
  changeset.prettyPrint();
}
